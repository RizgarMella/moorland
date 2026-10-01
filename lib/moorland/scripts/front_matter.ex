defmodule Moorland.Scripts.FrontMatter do
  @moduledoc """
  Front matter for prose: a block of `key: value` lines between `---` lines
  at the very top, as Markdown tools write it.

      ---
      title: The Keeper
      author: R. Mella
      contact: r@example.com
      dedication: For my father
      epigraph: The sea remembers. — Anon
      ---

  Keys are case-insensitive; unknown keys are kept but unused. The block is
  blanked (not removed) from the body so line numbers stay true.
  """

  @keys ~w(title author contact dedication epigraph)

  def keys, do: @keys

  @doc "`{fields, body}`: the front matter as a map (string keys) and the text with it blanked."
  def split(text) do
    text = text || ""
    lines = String.split(text, "\n")

    with [first | rest] <- lines,
         "---" <- String.trim(first),
         close when is_integer(close) <-
           Enum.find_index(Enum.take(rest, 40), &(String.trim(&1) == "---")) do
      fields =
        rest
        |> Enum.take(close)
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/^\s*([A-Za-z][A-Za-z ]*?)\s*:\s*(.*)$/, line) do
            [_, key, value] -> [{String.downcase(key), String.trim(value)}]
            nil -> []
          end
        end)
        |> Enum.reject(fn {_k, v} -> v == "" end)
        |> Map.new()

      blank = List.duplicate("", close + 2)
      {fields, Enum.join(blank ++ Enum.drop(rest, close + 1), "\n")}
    else
      _ -> {%{}, text}
    end
  end

  @doc "The text without its front matter (blanked, line numbers kept)."
  def body(text), do: text |> split() |> elem(1)
end
