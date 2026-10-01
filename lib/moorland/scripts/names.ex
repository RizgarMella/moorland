defmodule Moorland.Scripts.Names do
  @moduledoc """
  Character and place names in prose, the server's copy of the rules in
  assets/js/prose_names.js (which drives autocomplete): a word is a name
  when it is capitalised somewhere other than the start of a sentence and
  never written in lower case. Possessives count toward the name; headings,
  the boneyard, "I", acronyms and titles on their own do not. Runs of names
  seen together at least twice ("Anna Grey", "Dr. Okafor") count as names.
  """

  @titles ~w(Mr Mrs Ms Mx Dr Prof St Sr Jr Capt Sgt Lt Col Rev)
  @never MapSet.new(["I", "I'm", "I'll", "I'd", "I've", "OK", "Ok", "TV"])
  @word_re ~r/\p{L}[\p{L}'’\-]*/u
  @openers ["\"", "“", "'", "‘", "(", "[", "—", "–", "-", "*", "_", ">"]
  @enders [".", "!", "?", "…", ":"]

  @doc "Names, most used first: `[%{name, count}]`."
  def harvest(text) do
    occ = occurrences(text || "")

    {lower, mid, total} =
      Enum.reduce(occ, {MapSet.new(), %{}, %{}}, fn o, {lower, mid, total} ->
        if upper?(o.word) do
          mid = if o.initial, do: mid, else: Map.update(mid, o.word, 1, &(&1 + 1))
          {lower, mid, Map.update(total, o.word, 1, &(&1 + 1))}
        else
          {MapSet.put(lower, String.downcase(o.word)), mid, total}
        end
      end)

    name? = fn w ->
      Map.has_key?(mid, w) and not MapSet.member?(lower, String.downcase(w)) and
        not MapSet.member?(@never, w) and w not in @titles and String.length(w) >= 2 and
        w != String.upcase(w)
    end

    singles = for {w, n} <- total, name?.(w), into: %{}, do: {w, n}

    runs =
      occ
      |> Enum.chunk_while(
        [],
        fn o, run ->
          cond do
            run != [] and o.adjacent and name?.(o.word) -> {:cont, [o | run]}
            name?.(o.word) or o.word in @titles -> {:cont, Enum.reverse(run), [o]}
            true -> {:cont, Enum.reverse(run), []}
          end
        end,
        fn run -> {:cont, Enum.reverse(run), []} end
      )
      |> Enum.filter(&(length(&1) >= 2))
      |> Enum.map(fn run ->
        Enum.map_join(run, " ", fn o -> if o.word in @titles, do: o.word <> ".", else: o.word end)
      end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_phrase, n} -> n >= 2 end)
      |> Map.new()

    singles
    |> Map.merge(runs)
    |> Enum.map(fn {name, count} -> %{name: name, count: count} end)
    |> Enum.sort_by(&{-&1.count, &1.name})
  end

  defp upper?(word), do: Regex.match?(~r/^\p{Lu}/u, word)

  defp occurrences(text) do
    text
    |> String.replace(~r/\/\*[\s\S]*?\*\//, "")
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.flat_map(&line_occurrences/1)
  end

  defp line_occurrences(line) do
    @word_re
    |> Regex.scan(line, return: :index)
    |> Enum.map(fn [{start, len}] -> {start, len} end)
    |> Enum.map_reduce(nil, fn {start, len}, prev ->
      raw = binary_part(line, start, len)
      word = raw |> String.replace(~r/['’]s$/u, "") |> String.replace(~r/['’\-]+$/u, "")

      adjacent =
        case prev do
          {_pword, pend} -> Regex.match?(~r/^\.?\s$/, binary_part(line, pend, start - pend))
          nil -> false
        end

      prev_word = if adjacent, do: elem(prev, 0)

      o = %{
        word: word,
        adjacent: adjacent,
        initial: prev_word not in @titles and sentence_initial?(line, start)
      }

      {o, {word, start + len}}
    end)
    |> elem(0)
    |> Enum.reject(&(&1.word == ""))
  end

  # Skip back over spaces and opening marks: a sentence starts at the line's
  # start or after a full stop, question mark and the like.
  defp sentence_initial?(line, start) do
    line
    |> binary_part(0, start)
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 in [" ", "\t"] or &1 in @openers))
    |> case do
      [] -> true
      [char | _] -> char in @enders
    end
  end
end
