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
    elements = elements(text)

    scenes = for {:scene, text, _line} <- elements, do: text
    characters = character_stats(elements)

    words =
      elements
      |> Enum.map(fn {_type, text, _line} -> length(String.split(text, ~r/\s+/, trim: true)) end)
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

  @doc """
  Every scene in document order. `number` counts from 1 and identifies the
  scene within this text; `label` is the scene number to show: its fixed
  `#number#` if it has one, else its count, unless other scenes have fixed
  numbers (a locked script), when a new unnumbered scene's label is nil.
  `line` and `end_line` are 0-based source lines (the heading, and the last
  line before the next heading). `eighths` is the scene's length in eighths
  of a page, never less than one; `cast` lists who speaks in it;
  `synopsis` is the scene's `= synopsis` line, else its first line of
  action, cut to a line's length (or nil).
  """
  def scenes(text) do
    elements = elements(text)
    line_count = length(String.split(text || "", "\n"))

    {scenes, current} =
      Enum.reduce(elements, {[], nil}, fn
        {:scene, heading, line}, {acc, current} ->
          {close_scene(current, acc), new_scene(heading, line)}

        _el, {acc, nil} ->
          {acc, nil}

        el, {acc, scene} ->
          {acc, add_to_scene(scene, el)}
      end)

    scenes = close_scene(current, scenes) |> Enum.reverse()
    raw = (text || "") |> String.split("\n") |> List.to_tuple()

    fixed =
      Enum.map(scenes, fn scene ->
        raw |> elem(scene.line) |> String.trim() |> split_scene_number() |> elem(1)
      end)

    locked? = Enum.any?(fixed)

    scenes
    |> Enum.zip(fixed)
    |> Enum.with_index()
    |> Enum.map(fn {{scene, fixed}, i} ->
      next = Enum.at(scenes, i + 1)
      end_line = if next, do: next.line - 1, else: max(scene.line, line_count - 1)
      label = fixed || if(locked?, do: nil, else: Integer.to_string(i + 1))
      Map.merge(scene, %{number: i + 1, label: label, end_line: end_line})
    end)
  end

  @scene_number_re ~r/\s*#([A-Za-z0-9.\-]+)#\s*$/

  @doc """
  Splits a Fountain scene number off a heading:
  `INT. HOUSE - DAY #12A#` gives `{"INT. HOUSE - DAY", "12A"}`.
  """
  def split_scene_number(heading) do
    case Regex.run(@scene_number_re, heading, return: :index) do
      [{start, _len}, {num_start, num_len}] ->
        {binary_part(heading, 0, start), binary_part(heading, num_start, num_len)}

      nil ->
        {heading, nil}
    end
  end

  @doc "The location part of a scene heading: `INT. KITCHEN - NIGHT` gives `KITCHEN`."
  def location(heading) do
    heading
    |> String.replace(@scene_re, "")
    |> String.split(~r/\s+-\s+/)
    |> List.first()
    |> String.trim()
  end

  @doc "`:int`, `:ext`, `:int_ext` or `:other` for a scene heading."
  def int_ext_of(heading) do
    cond do
      Regex.match?(~r/^(INT\.\/EXT|INT\/EXT|I\/E)/, heading) -> :int_ext
      String.starts_with?(heading, "INT") -> :int
      String.starts_with?(heading, "EXT") -> :ext
      true -> :other
    end
  end

  @doc "The time-of-day part of a scene heading, or `nil` when it has none."
  def time_of(heading) do
    case String.split(heading, ~r/\s+-\s+/) do
      [_] -> nil
      parts -> parts |> List.last() |> String.trim()
    end
  end

  defp new_scene(heading, line) do
    %{
      line: line,
      heading: heading,
      int_ext: int_ext_of(heading),
      time: time_of(heading),
      location: location(heading),
      cost: cost_of({:scene, heading, line}),
      cast: [],
      synopsis: nil,
      first_action: nil
    }
  end

  defp add_to_scene(scene, {:character, t, _line} = el) do
    name = cue_name(t)
    cast = if name in scene.cast, do: scene.cast, else: scene.cast ++ [name]
    %{scene | cost: scene.cost + cost_of(el), cast: cast}
  end

  defp add_to_scene(%{synopsis: nil} = scene, {:synopsis, t, _line} = el),
    do: %{scene | cost: scene.cost + cost_of(el), synopsis: t}

  defp add_to_scene(%{first_action: nil} = scene, {:action, t, _line} = el),
    do: %{scene | cost: scene.cost + cost_of(el), first_action: t}

  defp add_to_scene(scene, el), do: %{scene | cost: scene.cost + cost_of(el)}

  defp close_scene(nil, acc), do: acc

  defp close_scene(scene, acc) do
    eighths = max(1, ceil(scene.cost * 8 / @lines_per_page))

    synopsis =
      case scene.synopsis || scene.first_action do
        nil ->
          nil

        text ->
          # Plain words for a one-liner: no *emphasis* or _underline_ marks.
          text =
            text
            |> String.replace(~r/(\*{1,3}|_)(?=\S)(.+?)(?<=\S)\1/, "\\2")
            |> String.trim_leading("!")

          if String.length(text) > 90, do: String.slice(text, 0, 89) <> "…", else: text
      end

    [
      scene
      |> Map.drop([:cost, :first_action])
      |> Map.merge(%{eighths: eighths, synopsis: synopsis})
      | acc
    ]
  end

  # Classified elements as {type, text, source_line}. Boneyard and title page
  # are blanked rather than dropped, so line numbers match the source.
  defp elements(text) do
    (text || "")
    |> strip_boneyard()
    |> String.split("\n")
    |> strip_title_page()
    |> classify()
  end

  @doc """
  Statistics for prose, in the same shape as `compute/1` so reports, goals
  and sprints work unchanged: `pages` are manuscript pages (about 250 words
  each), `minutes` reading time, `chapters` the `#` headings. Markdown marks
  are not words.
  """
  def compute_prose(text) do
    lines =
      text |> Moorland.Scripts.FrontMatter.body() |> strip_boneyard() |> String.split("\n")

    words =
      lines
      |> Enum.reject(&Regex.match?(~r/^\s*([*\-_]\s*){3,}$/, &1))
      |> Enum.map(fn line ->
        line
        |> String.replace(~r/^\s*(#+|>)\s*/, "")
        |> String.replace(~r/[*_]+/, " ")
        |> String.split(~r/\s+/, trim: true)
        |> length()
      end)
      |> Enum.sum()

    chapters = Enum.count(lines, &Regex.match?(~r/^#\s+\S/, &1))

    %{
      prose: true,
      pages: if(words == 0, do: 0, else: max(1, ceil(words / 250))),
      minutes: if(words == 0, do: 0, else: max(1, ceil(words / 230))),
      words: words,
      chapters: chapters,
      scene_count: 0,
      int_ext: %{int: 0, ext: 0, other: 0},
      times: [],
      characters: [],
      locations: []
    }
  end

  @speech_wpm 150

  @doc """
  Statistics for a podcast episode: everything `compute/1` gives, with
  `characters` as the speakers, plus `segments` (each `#` section with its
  spoken words, its length, and any length written in its `= 1:30`
  synopsis) and `seconds` in all. Speech runs at #{@speech_wpm} words a minute;
  a segment with no speech (an ad break, a music bed) lasts as long as its
  synopsis says. Only dialogue counts as speech: action lines are cues for
  the engineer.
  """
  def compute_podcast(text) do
    elements = elements(text)

    segments =
      elements
      |> Enum.reduce([], fn
        {:section, title, _line}, acc ->
          [%{title: title, words: 0, target: nil} | acc]

        {:synopsis, t, _line}, [%{target: nil} = seg | rest] ->
          [%{seg | target: parse_duration(t)} | rest]

        {:dialogue, t, _line}, acc ->
          words = length(String.split(t, ~r/\s+/, trim: true))

          case acc do
            [] -> [%{title: "Opening", words: words, target: nil}]
            [seg | rest] -> [%{seg | words: seg.words + words} | rest]
          end

        _el, acc ->
          acc
      end)
      |> Enum.reverse()
      |> Enum.map(fn seg ->
        spoken = round(seg.words * 60 / @speech_wpm)
        Map.put(seg, :seconds, if(seg.words > 0, do: spoken, else: seg.target || 0))
      end)

    seconds = segments |> Enum.map(& &1.seconds) |> Enum.sum()

    text
    |> compute()
    |> Map.merge(%{
      podcast: true,
      segments: segments,
      seconds: seconds,
      minutes: if(seconds == 0, do: 0, else: max(1, ceil(seconds / 60))),
      scene_count: 0,
      locations: []
    })
  end

  @doc "Seconds in a written length: `1:30`, `90s`, `2 min`, `45 sec`; nil if none."
  def parse_duration(text) do
    t = text |> String.trim() |> String.downcase()

    cond do
      m = Regex.run(~r/^(\d+):([0-5]\d)$/, t) ->
        [_, mins, secs] = m
        String.to_integer(mins) * 60 + String.to_integer(secs)

      m = Regex.run(~r/^(\d+)\s*(s|sec|secs|seconds)$/, t) ->
        m |> Enum.at(1) |> String.to_integer()

      m = Regex.run(~r/^(\d+)\s*(m|min|mins|minutes)$/, t) ->
        (m |> Enum.at(1) |> String.to_integer()) * 60

      true ->
        nil
    end
  end

  @doc "`compute/1` for a screenplay, `compute_prose/1` for prose, `compute_podcast/1` for a podcast."
  def compute_for(%{kind: "prose"}, text), do: compute_prose(text)
  def compute_for(%{kind: "podcast"}, text), do: compute_podcast(text)

  # A lesson is timed like a podcast: narration at speaking pace, by part.
  def compute_for(%{kind: "lesson"}, text),
    do: text |> compute_podcast() |> Map.merge(%{podcast: false, lesson: true})

  def compute_for(_script, text), do: compute(text)

  defp strip_boneyard(text) do
    Regex.replace(~r/\/\*[\s\S]*?\*\//, text, fn match ->
      match |> String.replace(~r/[^\n]/, "")
    end)
  end

  defp strip_title_page([first | _] = lines) do
    if Regex.match?(@title_key_re, first) do
      {title, rest} =
        Enum.split_while(lines, fn line ->
          String.trim(line) != "" and
            (Regex.match?(@title_key_re, line) or Regex.match?(~r/^\s+\S/, line))
        end)

      List.duplicate("", length(title)) ++ rest
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
        t == "" ->
          {acc, false}

        t == "===" ->
          {acc, false}

        String.starts_with?(t, "#") ->
          {[{:section, String.replace(t, ~r/^#+\s*/, ""), i} | acc], false}

        String.starts_with?(t, "=") ->
          {[{:synopsis, String.replace(t, ~r/^=\s*/, ""), i} | acc], false}

        String.starts_with?(t, ">") and String.ends_with?(t, "<") ->
          {[{:centered, t, i} | acc], false}

        scene_heading?(t) and prev_blank ->
          {heading, _number} = t |> String.trim_leading(".") |> split_scene_number()
          {[{:scene, String.upcase(heading), i} | acc], false}

        transition?(t) and prev_blank ->
          {[{:transition, t, i} | acc], false}

        character_cue?(t, prev_blank, next_line) ->
          {[{:character, t, i} | acc], true}

        in_dialogue and String.starts_with?(t, "(") and String.ends_with?(t, ")") ->
          {[{:parenthetical, t, i} | acc], true}

        in_dialogue ->
          {[{:dialogue, String.trim_leading(t, "~"), i} | acc], true}

        true ->
          {[{:action, t, i} | acc], false}
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
      String.starts_with?(t, "@") ->
        prev_blank and not next_blank

      not prev_blank or next_blank ->
        false

      t == "" or String.length(t) > 60 ->
        false

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

  defp cost_of({:scene, t, _}), do: rows(t, 60) + 2
  defp cost_of({:action, t, _}), do: rows(t, 60) + 1
  defp cost_of({:character, _, _}), do: 2
  defp cost_of({:parenthetical, t, _}), do: rows(t, 25)
  defp cost_of({:dialogue, t, _}), do: rows(t, 35)
  defp cost_of({:transition, _, _}), do: 2
  defp cost_of({:centered, _, _}), do: 2
  defp cost_of({:section, _, _}), do: 2
  defp cost_of({:synopsis, _, _}), do: 1

  defp rows(t, width), do: max(1, ceil(String.length(t) / width))

  defp character_stats(elements) do
    {stats, _current} =
      Enum.reduce(elements, {%{}, nil}, fn
        {:character, t, _}, {stats, _} ->
          name = cue_name(t)
          {Map.put_new(stats, name, %{lines: 0, words: 0}), name}

        {:dialogue, t, _}, {stats, current} when current != nil ->
          words = length(String.split(t, ~r/\s+/, trim: true))

          {Map.update!(stats, current, fn s ->
             %{s | lines: s.lines + 1, words: s.words + words}
           end), current}

        {:parenthetical, _, _}, {stats, current} ->
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
      case int_ext_of(heading) do
        :int_ext -> %{acc | int: acc.int + 1, ext: acc.ext + 1}
        :int -> %{acc | int: acc.int + 1}
        :ext -> %{acc | ext: acc.ext + 1}
        :other -> %{acc | other: acc.other + 1}
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
    |> Enum.map(&location/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {name, count} -> {-count, name} end)
  end
end
