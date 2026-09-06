defmodule Moorland.Lookup do
  @moduledoc """
  The Lookup panel's word service: definitions, synonyms and rhymes via the
  free Datamuse API. Needs internet; fails soft with a clear offline message.
  """

  def fetch(word) do
    word = word |> to_string() |> String.trim() |> String.slice(0, 60)

    if word == "" do
      {:error, :empty}
    else
      with {:ok, defs} <- get("sp=#{URI.encode_www_form(word)}&md=d&max=1"),
           {:ok, syns} <- get("rel_syn=#{URI.encode_www_form(word)}&max=12"),
           {:ok, rhys} <- get("rel_rhy=#{URI.encode_www_form(word)}&max=12") do
        {:ok,
         %{
           word: word,
           definitions: parse_definitions(defs),
           synonyms: Enum.map(syns, & &1["word"]),
           rhymes: Enum.map(rhys, & &1["word"])
         }}
      end
    end
  end

  @doc "Turns Datamuse's tab-prefixed defs into {part_of_speech, text} pairs."
  def parse_definitions([%{"defs" => defs} | _]) when is_list(defs) do
    defs
    |> Enum.take(5)
    |> Enum.map(fn def ->
      case String.split(def, "\t", parts: 2) do
        [pos, text] -> {expand_pos(pos), text}
        [text] -> {"", text}
      end
    end)
  end

  def parse_definitions(_), do: []

  defp expand_pos("n"), do: "noun"
  defp expand_pos("v"), do: "verb"
  defp expand_pos("adj"), do: "adjective"
  defp expand_pos("adv"), do: "adverb"
  defp expand_pos(other), do: other

  defp get(query) do
    url = String.to_charlist("https://api.datamuse.com/words?#{query}")

    ssl_options = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    options = [ssl: ssl_options, timeout: 6_000, connect_timeout: 4_000]

    case :httpc.request(:get, {url, [{~c"user-agent", ~c"moorland"}]}, options,
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, list} when is_list(list) -> {:ok, list}
          _ -> {:error, :bad_response}
        end

      _ ->
        {:error, :offline}
    end
  rescue
    _ -> {:error, :offline}
  end
end
