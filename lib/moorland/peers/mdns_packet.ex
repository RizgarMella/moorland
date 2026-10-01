defmodule Moorland.Peers.MdnsPacket do
  @moduledoc """
  The few parts of DNS that answering for one `.local` name needs, as pure
  functions: reading the questions in a query (with name compression), and
  writing a response carrying A records. RFC 1035 wire format with the
  mDNS conventions of RFC 6762: responses are authoritative, answers set
  the cache-flush bit, and the top bit of a question's class asks for a
  unicast reply.
  """

  import Bitwise

  @type_a 1
  @type_any 255
  @class_in 1

  def type_a, do: @type_a
  def type_any, do: @type_any

  @doc """
  The questions in a query: `{:ok, %{id, questions: [%{name, type, unicast?}]}}`.
  Responses (QR set) and anything malformed are `:ignore`.
  """
  def decode_query(
        <<id::16, qr::1, _opcode::4, _flags::11, qdcount::16, _an::16, _ns::16, _ar::16,
          _rest::binary>> = packet
      )
      when qr == 0 do
    case questions(packet, 12, qdcount, []) do
      {:ok, questions} -> {:ok, %{id: id, questions: questions}}
      :error -> :ignore
    end
  end

  def decode_query(_packet), do: :ignore

  defp questions(_packet, _offset, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp questions(packet, offset, n, acc) do
    with {:ok, name, offset} <- read_name(packet, offset, 0),
         <<_::binary-size(offset), type::16, class::16, _::binary>> <- packet do
      question = %{
        name: name,
        type: type,
        unicast?: (class &&& 0x8000) != 0,
        class: class &&& 0x7FFF
      }

      questions(packet, offset + 4, n - 1, [question | acc])
    else
      _ -> :error
    end
  end

  # A name: length-prefixed labels ending in a zero byte, or a pointer
  # (top two bits set) to a name earlier in the packet. `hops` bounds
  # pointer chains so a hostile packet can't loop us.
  defp read_name(packet, offset, hops, labels \\ [])

  defp read_name(_packet, _offset, hops, _labels) when hops > 16, do: :error

  defp read_name(packet, offset, hops, labels) do
    case packet do
      <<_::binary-size(offset), 0, _::binary>> ->
        {:ok, labels |> Enum.reverse() |> Enum.join(".") |> String.downcase(), offset + 1}

      <<_::binary-size(offset), 0b11::2, pointer::14, _::binary>> ->
        case read_name(packet, pointer, hops + 1, labels) do
          {:ok, name, _} -> {:ok, name, offset + 2}
          :error -> :error
        end

      <<_::binary-size(offset), 0b00::2, len::6, label::binary-size(len), _::binary>> ->
        read_name(packet, offset + 1 + len, hops, [label | labels])

      _ ->
        :error
    end
  end

  @doc """
  A response holding an A record for `name` per address. With `query`
  (a legacy unicast question, RFC 6762 §6.7) it echoes the query's id and
  question, as an ordinary DNS resolver expects.
  """
  def encode_response(name, addresses, ttl, query \\ nil) do
    {id, question} =
      case query do
        %{id: id} -> {id, encode_name(name) <> <<@type_a::16, @class_in::16>>}
        nil -> {0, ""}
      end

    qdcount = if question == "", do: 0, else: 1
    # Unicast replies to a legacy resolver must not set cache-flush.
    class = if query, do: @class_in, else: @class_in ||| 0x8000

    answers =
      for {a, b, c, d} <- addresses, into: "" do
        encode_name(name) <> <<@type_a::16, class::16, ttl::32, 4::16, a, b, c, d>>
      end

    <<id::16, 0x8400::16, qdcount::16, length(addresses)::16, 0::16, 0::16>> <>
      question <> answers
  end

  @doc "A query for `name` (for tests, and for checking a name is free)."
  def encode_query(name, id \\ 0, unicast? \\ false) do
    class = if unicast?, do: @class_in ||| 0x8000, else: @class_in

    <<id::16, 0::16, 1::16, 0::16, 0::16, 0::16>> <>
      encode_name(name) <> <<@type_a::16, class::16>>
  end

  @doc "The A records in a response: `[{name, {a, b, c, d}}]`."
  def decode_answers(<<_id::16, _flags::16, qdcount::16, ancount::16, _::32, _::binary>> = packet) do
    with {:ok, offset} <- skip_questions(packet, 12, qdcount) do
      read_answers(packet, offset, ancount, [])
    end
  end

  def decode_answers(_packet), do: []

  defp skip_questions(_packet, offset, 0), do: {:ok, offset}

  defp skip_questions(packet, offset, n) do
    case read_name(packet, offset, 0) do
      {:ok, _name, offset} -> skip_questions(packet, offset + 4, n - 1)
      :error -> :error
    end
  end

  defp read_answers(_packet, _offset, 0, acc), do: Enum.reverse(acc)

  defp read_answers(packet, offset, n, acc) do
    with {:ok, name, offset} <- read_name(packet, offset, 0),
         <<_::binary-size(offset), type::16, _class::16, _ttl::32, len::16,
           data::binary-size(len), _::binary>> <- packet do
      acc =
        case {type, data} do
          {@type_a, <<a, b, c, d>>} -> [{name, {a, b, c, d}} | acc]
          _ -> acc
        end

      read_answers(packet, offset + 10 + len, n - 1, acc)
    else
      _ -> Enum.reverse(acc)
    end
  end

  defp encode_name(name) do
    labels =
      for label <- String.split(name, ".", trim: true), into: "" do
        <<byte_size(label)>> <> label
      end

    labels <> <<0>>
  end
end
