defmodule Moorland.Peers.Crypto do
  @moduledoc """
  Ed25519 identity for peer-to-peer trust: every installation holds a keypair,
  every peer request is signed, and a "peer code" bundles the public key with
  a reachable address.
  """

  def generate_keypair do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: public, private: private}
  end

  def sign(message, private_key) when is_binary(message) do
    :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])
  end

  def verify(message, signature, public_key)
      when is_binary(message) and is_binary(signature) and is_binary(public_key) do
    :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  end

  def fingerprint(public_key) do
    :crypto.hash(:sha256, public_key)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  def encode_key(key), do: Base.url_encode64(key, padding: false)
  def decode_key(string), do: Base.url_decode64(string, padding: false)

  @doc ~S/Formats a shareable peer code: moor:<key>@host:port/
  def format_code(public_key, host, port) do
    "moor:#{encode_key(public_key)}@#{host}:#{port}"
  end

  @doc "Parses a peer code back into its parts."
  def parse_code(code) when is_binary(code) do
    with "moor:" <> rest <- String.trim(code),
         [key64, address] <- String.split(rest, "@", parts: 2),
         {host, port_s} <- split_address(address),
         {:ok, public_key} <- decode_key(key64),
         32 <- byte_size(public_key),
         {port, ""} when port in 1..65_535 <- Integer.parse(port_s) do
      {:ok, %{public_key: public_key, host: host, port: port}}
    else
      _ -> {:error, :invalid_code}
    end
  end

  defp split_address(address) do
    case String.split(address, ":") do
      parts when length(parts) >= 2 ->
        {port_s, host_parts} = List.pop_at(parts, -1)
        {Enum.join(host_parts, ":"), port_s}

      _ ->
        :error
    end
  end
end
