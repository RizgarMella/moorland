defmodule Moorland.Scripts.Stats do
  @moduledoc """
  Screenplay statistics computed from Fountain text: estimated pages and
  runtime, scene mix, speaking parts and locations. Mirrors the client-side
  classifier closely enough for reporting purposes.
  """

  @scene_re ~r/^(INT\.\/EXT|INT\/EXT|I\/E|INT|EXT|EST)[.\s]/i
  @transition_re ~r/^[A-Z0-9 .']+TO:$/
  @title_key_re ~r/^[A-Za-z ]+:\s*/
  @lines_per_page 55
  @known_times ~w(DAY NIGHT MORNING EVENING AFTERNOON DUSK DAWN CONTINUOUS LATER SAME SUNSET SUNRISE)

  def compute(text) do
    lines =
      (text || "")
      |> strip_boneyard()
      |> String.split("\n")
      |> strip_title_page()

    elements = classify(lines)

    scenes = for {:scene, text} <- elements, do: text
    characters = character_stats(elements)

    words =
      elements
      |> Enum.map(fn {_type, text} -> length(String.split(text, ~r/\s+/, trim: true)) end)
      |> Enum.sum()

    cost = Enum.reduce(elements, 0, fn el, acc -> acc + cost_of(el) end)
    pages = if cost == 0, do: 0, else: max(1, ceil(cost / @lines_per_page))

    %{
      pages: pages,
      minutes: pages,
      words: words,
      scene_count: length(scenes),
      int_ext: int_ext(scenes),
      times: times(scenes),
      characters: characters,
      locations: locations(scenes)
    }
  end

  defp strip_boneyard(text) do
    Regex.replace(~r/\/\*[\s\S]*?\*\//, text, fn match ->
      match |> String.replace(~r/[^\n]/, "")
    end)
  end

  defp strip_title_page([first | _] = lines) do
    if Regex.match?(@title_key_re, first) do
      Enum.drop_while(lines, fn line ->
        String.trim(line) != "" and
          (Regex.match?(@title_key_re, line) or Regex.match?(~r/^\s+\S/, line))
      end)
    else
      lines
    end
  end

  defp strip_title_page([]), do: []

  defp classify(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce({[], false}, fn {line, i}, {acc, in_dialogue} ->
      t = String.trim(line)
      prev_blank = i == 0 or String.trim(Enum.at(lines, i - 1) || "") == ""
      next_line = Enum.at(lines, i + 1)

      cond do
        t == "" -> {acc, false}
        t == "===" -> {acc, false}
        String.starts_with?(t, "#") -> {[{:section, String.replace(t, ~r/^#+\s*/, "")} | acc], false}
        String.starts_with?(t, "=") -> {[{:synopsis, String.replace(t, ~r/^=\s*/, "")} | acc], false}
        String.starts_with?(t, ">") and String.ends_with?(t, "<") ->
          {[{:centered, t} | acc], false}

        scene_heading?(t) and prev_blank ->
          heading = t |> String.trim_leading(".") |> String.upcase()
          {[{:scene, heading} | acc], false}

        transition?(t) and prev_blank ->
          {[{:transition, t} | acc], false}

        character_cue?(t, prev_blank, next_line) ->
          {[{:character, t} | acc], true}

        in_dialogue and String.starts_with?(t, "(") and String.ends_with?(t, ")") ->
          {[{:parenthetical, t} | acc], true}

        in_dialogue ->
          {[{:dialogue, String.trim_leading(t, "~")} | acc], true}

        true ->
          {[{:action, t} | acc], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp scene_heading?(t) do
    Regex.match?(@scene_re, t) or
      (String.starts_with?(t, ".") and not String.starts_with?(t, ".."))
  end

  defp transition?(t) do
    (String.starts_with?(t, ">") and not String.ends_with?(t, "<")) or
      (Regex.match?(@transition_re, t) and t == String.upcase(t))
  end

  defp character_cue?(t, prev_blank, next_line) do
    next_blank = next_line == nil or String.trim(next_line) == ""

    cond do
      String.starts_with?(t, "@") -> prev_blank and not next_blank
      not prev_blank or next_blank -> false
      t == "" or String.length(t) > 60 -> false
      true ->
        base = String.replace(t, ~r/\s*\([^)]*\)\s*$/, "")

        base != "" and Regex.match?(~r/[A-Z]/, base) and base == String.upcase(base) and
          not scene_heading?(t) and not transition?(t) and
          Regex.match?(~r/^[A-Z0-9 .'\-#]+$/, base)
    end
  end

  defp cue_name(t) do
    t
    |> String.trim_leading("@")
    |> String.replace(~r/\s*\([^)]*\)\s*$/, "")
    |> String.trim()
  end

  defp cost_of({:scene, t}), do: rows(t, 60) + 2
  defp cost_of({:action, t}), do: rows(t, 60) + 1
  defp cost_of({:character, _}), do: 2
  defp cost_of({:parenthetical, t}), do: rows(t, 25)
  defp cost_of({:dialogue, t}), do: rows(t, 35)
  defp cost_of({:transition, _}), do: 2
  defp cost_of({:centered, _}), do: 2
  defp cost_of({:section, _}), do: 2
  defp cost_of({:synopsis, _}), do: 1

  defp rows(t, width), do: max(1, ceil(String.length(t) / width))

  defp character_stats(elements) do
    {stats, _current} =
      Enum.reduce(elements, {%{}, nil}, fn
        {:character, t}, {stats, _} ->
          name = cue_name(t)
          {Map.put_new(stats, name, %{lines: 0, words: 0}), name}

        {:dialogue, t}, {stats, current} when current != nil ->
          words = length(String.split(t, ~r/\s+/, trim: true))

          {Map.update!(stats, current, fn s ->
             %{s | lines: s.lines + 1, words: s.words + words}
           end), current}

        {:parenthetical, _}, {stats, current} ->
          {stats, current}

        _other, {stats, _} ->
          {stats, nil}
      end)

    stats
    |> Enum.map(fn {name, s} -> Map.put(s, :name, name) end)
    |> Enum.sort_by(&{-&1.words, &1.name})
  end

  defp int_ext(scenes) do
    Enum.reduce(scenes, %{int: 0, ext: 0, other: 0}, fn heading, acc ->
      cond do
        Regex.match?(~r/^(INT\.\/EXT|INT\/EXT|I\/E)/, heading) ->
          %{acc | int: acc.int + 1, ext: acc.ext + 1}

        String.starts_with?(heading, "INT") -> %{acc | int: acc.int + 1}
        String.starts_with?(heading, "EXT") -> %{acc | ext: acc.ext + 1}
        true -> %{acc | other: acc.other + 1}
      end
    end)
  end

  defp times(scenes) do
    scenes
    |> Enum.map(fn heading ->
      case String.split(heading, ~r/\s+-\s+/) do
        [_] ->
          "UNSPECIFIED"

        parts ->
          time = parts |> List.last() |> String.trim()
          if time in @known_times or String.contains?(time, "LATER"), do: time, else: "OTHER"
      end
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_label, count} -> -count end)
  end

  defp locations(scenes) do
    scenes
    |> Enum.map(fn heading ->
      heading
      |> String.replace(@scene_re, "")
      |> String.split(~r/\s+-\s+/)
      |> List.first()
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {name, count} -> {-count, name} end)
  end
end
