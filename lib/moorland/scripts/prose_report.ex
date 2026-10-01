defmodule Moorland.Scripts.ProseReport do
  @moduledoc """
  The writer's report for prose: chapter lengths, and style checks that
  point at lines rather than rewrite them. Pure functions over the text.

    * echoes: the same word of four letters or more used three times or
      more in one paragraph (names and common words aside)
    * adverbs: -ly words, without the -ly words that are not adverbs
    * passive voice: a form of "to be" followed by a past participle
    * dialogue tags: plain "said" and "asked" against showier tags

  Findings carry the 0-based source line they start on, for Go to.
  """

  @wpm 230

  @stop ~w(that this with from have were they them their there then than what when
           where which while would could should about into your just been only some
           more very like over said asked back down even ever also into onto upon
           does done each such much many most well here here's it's that's don't
           didn't wasn't couldn't wouldn't)

  @not_adverbs ~w(only early family reply apply supply rely fly ugly holy belly bully
                  jelly lily july italy daily holly silly lonely lovely friendly likely
                  ally rally tally folly jolly melancholy assembly anomaly monopoly
                  homily butterfly dragonfly firefly)

  @be ~w(am is are was were be been being)

  @irregular ~w(seen done taken given made known shown written broken chosen driven
                eaten fallen forgotten hidden spoken stolen thrown worn born built
                caught felt found held kept left lost meant met paid sent sold told
                thought brought bought taught begun drunk sung swum hung struck torn
                shaken woken frozen ridden risen beaten bitten bound bred burnt dealt
                dug fed fought forbidden forgiven grown hurt laid led lent lit put read
                rung sat shut slept spent split spread stuck stung sworn swept)

  @plain_tags ~w(said says asked asks)
  @showy_tags ~w(exclaimed retorted hissed snapped growled muttered shouted cried
                 replied demanded insisted sighed laughed snarled barked breathed
                 murmured stammered declared whispered yelled screamed gasped
                 chuckled smirked spat bellowed purred)

  def analyze(text) do
    lines =
      text |> Moorland.Scripts.FrontMatter.body() |> strip_boneyard() |> String.split("\n")

    paragraphs = paragraphs(lines)

    %{
      chapters: chapters(lines),
      echoes: echoes(paragraphs),
      adverbs: adverbs(paragraphs),
      passive: passive(paragraphs),
      tags: tags(paragraphs)
    }
  end

  defp strip_boneyard(text) do
    Regex.replace(~r/\/\*[\s\S]*?\*\//, text, fn m -> String.replace(m, ~r/[^\n]/, "") end)
  end

  # {first_line, text} for each paragraph (headings and breaks aside).
  defp paragraphs(lines) do
    lines
    |> Enum.with_index()
    |> Enum.chunk_while(
      nil,
      fn {line, i}, acc ->
        cond do
          String.trim(line) == "" or Regex.match?(~r/^\s*#|^\s*([*\-_]\s*){3,}$/, line) ->
            if acc, do: {:cont, acc, nil}, else: {:cont, nil}

          acc ->
            {:cont, {elem(acc, 0), elem(acc, 1) <> " " <> String.trim(line)}}

          true ->
            {:cont, {i, String.trim(line)}}
        end
      end,
      fn acc -> if acc, do: {:cont, acc, nil}, else: {:cont, nil} end
    )
  end

  defp words(text), do: Regex.scan(~r/\p{L}[\p{L}'’]*/u, text) |> List.flatten()

  @doc false
  def chapters(lines) do
    {chapters, current} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {line, i}, {done, current} ->
        case Regex.run(~r/^#\s+(.+)$/, String.trim(line)) do
          [_, title] ->
            {close(current, done), %{title: String.trim(title), line: i, words: 0}}

          nil ->
            n = if Regex.match?(~r/^\s*#/, line), do: 0, else: length(words(line))

            cond do
              current -> {done, %{current | words: current.words + n}}
              n > 0 -> {done, %{title: "Opening", line: i, words: n}}
              true -> {done, nil}
            end
        end
      end)

    close(current, chapters)
    |> Enum.reverse()
    |> Enum.map(&Map.put(&1, :minutes, max(1, ceil(&1.words / @wpm))))
  end

  defp close(nil, done), do: done
  defp close(chapter, done), do: [chapter | done]

  defp echoes(paragraphs) do
    for {line, text} <- paragraphs,
        {word, count} <-
          text
          |> words()
          |> Enum.reject(&Regex.match?(~r/^\p{Lu}/u, &1))
          |> Enum.map(&String.downcase/1)
          |> Enum.filter(&(String.length(&1) >= 4 and &1 not in @stop))
          |> Enum.frequencies(),
        count >= 3 do
      %{word: word, count: count, line: line}
    end
    |> Enum.sort_by(&{-&1.count, &1.line})
  end

  defp adverbs(paragraphs) do
    found =
      for {line, text} <- paragraphs,
          word <- words(text),
          lower = String.downcase(word),
          String.ends_with?(lower, "ly") and String.length(lower) > 4 and
            lower not in @not_adverbs do
        {lower, line}
      end

    %{
      count: length(found),
      top:
        found
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.map(fn {word, lines} -> %{word: word, count: length(lines), line: hd(lines)} end)
        |> Enum.sort_by(&{-&1.count, &1.word})
        |> Enum.take(8)
    }
  end

  defp passive(paragraphs) do
    be = Enum.join(@be, "|")

    found =
      for {line, text} <- paragraphs,
          [phrase, participle] <-
            Regex.scan(~r/\b(?:#{be})\s+(?:\w+ly\s+)?(\w+)\b/iu, text),
          passive_participle?(String.downcase(participle)) do
        %{phrase: phrase, line: line}
      end

    %{count: length(found), examples: Enum.take(found, 8)}
  end

  defp passive_participle?(word),
    do: word in @irregular or (String.ends_with?(word, "ed") and String.length(word) > 3)

  defp tags(paragraphs) do
    text = paragraphs |> Enum.map(&elem(&1, 1)) |> Enum.join(" ")
    all = text |> words() |> Enum.map(&String.downcase/1)

    plain = Enum.count(all, &(&1 in @plain_tags))

    showy =
      all
      |> Enum.filter(&(&1 in @showy_tags))
      |> Enum.frequencies()
      |> Enum.sort_by(fn {word, n} -> {-n, word} end)

    %{plain: plain, showy: showy}
  end
end
