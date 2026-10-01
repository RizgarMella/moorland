defmodule Moorland.Scripts.PdfImport do
  @moduledoc """
  Melts a screenplay PDF back into editable Fountain.

  A screenplay's layout says what each line is: in a standard script, action
  and scene headings sit at the left margin, dialogue about ten characters
  in, parentheticals about fifteen, character cues about twenty-two, and
  transitions hard right. So the text runs from `Moorland.Pdf` are put back
  into lines, the left margin found, and each line classed by how far in it
  starts (measured in character widths, so any font size works). Wrapped
  lines are rejoined, page numbers, "(MORE)" and repeated "(CONT'D)" cues
  are dropped, scene numbers kept as Fountain `#12#`, and a first page with
  no scenes becomes the title page.

  Best effort by nature: a PDF records where ink goes, not what it meant.
  """

  alias Moorland.Pdf

  @scene_re ~r/^(INT\.?\/EXT|INT\/EXT|I\/E|INT|EXT|EST)[.\s]/i

  def to_fountain(binary) do
    with {:ok, pages} <- Pdf.text_runs(binary) do
      pages = Enum.map(pages, &lines/1)

      if Enum.all?(pages, &(&1 == [])) do
        {:error, :no_text}
      else
        {:ok, assemble(pages)}
      end
    end
  end

  ## Lines

  # Runs on the same baseline become a line, left to right, with a space
  # where the gap between runs is wider than a fraction of a character.
  defp lines(runs) do
    runs
    |> Enum.sort_by(&{-&1.y, &1.x})
    |> Enum.chunk_while(
      [],
      fn run, acc ->
        case acc do
          [] -> {:cont, [run]}
          [first | _] when abs(first.y - run.y) <= first.size * 0.35 -> {:cont, [run | acc]}
          _ -> {:cont, Enum.reverse(acc), [run]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.map(fn line_runs ->
      [first | _] = sorted = Enum.sort_by(line_runs, & &1.x)

      {text, _} =
        Enum.reduce(sorted, {"", nil}, fn run, {text, prev} ->
          gap = if prev, do: run.x - prev.end_x, else: 0

          sep =
            if prev != nil and gap > run.size * 0.25 and not String.ends_with?(text, " "),
              do: " ",
              else: ""

          {text <> sep <> run.text, run}
        end)

      %{
        x: first.x,
        y: first.y,
        size: first.size,
        text: String.trim(text),
        char: char_width(sorted)
      }
    end)
    |> Enum.reject(&(&1.text == ""))
  end

  # The width of one character, from the runs themselves (Courier is 0.6 em).
  defp char_width(runs) do
    widths =
      for r <- runs, n = String.length(r.text), n >= 3, do: (r.end_x - r.x) / n

    case widths do
      [] -> hd(runs).size * 0.6
      ws -> Enum.sum(ws) / length(ws)
    end
  end

  ## Classifying

  defp assemble(pages) do
    {title_page, pages} = title_page(pages)
    margin = margin(pages)

    elements =
      pages
      |> Enum.flat_map(fn page -> page |> drop_furniture() |> classify(margin) end)
      |> merge()

    body = Enum.map_join(elements, "\n\n", &render/1)
    String.trim(title_page <> body) <> "\n"
  end

  # The action margin: the left edge most lines share.
  defp margin(pages) do
    pages
    |> List.flatten()
    |> Enum.map(&Float.round(&1.x, 0))
    |> Enum.frequencies()
    |> Enum.max_by(fn {x, n} -> {n, -x} end, fn -> {72.0, 0} end)
    |> elem(0)
  end

  # Page numbers ("12.", "12A."), headers and footers, "(MORE)".
  defp drop_furniture(page) do
    {top, bottom} =
      case page do
        [] -> {0, 0}
        _ -> {Enum.max_by(page, & &1.y).y, Enum.min_by(page, & &1.y).y}
      end

    Enum.reject(page, fn line ->
      Regex.match?(~r/^\(?MORE\)?$/i, line.text) or
        (Regex.match?(~r/^\d+[A-Z]?\.?$/, line.text) and
           (line.y >= top - 1 or line.y <= bottom + 1))
    end)
  end

  defp classify(page, margin) do
    page
    |> Enum.with_index()
    |> Enum.map(fn {line, i} ->
      prev = if i > 0, do: Enum.at(page, i - 1)
      leading = if prev, do: prev.y - line.y, else: 999
      indent = (line.x - margin) / line.char
      %{text: line.text, kind: kind(line.text, indent), gap: leading / line.size}
    end)
  end

  defp kind(text, indent) do
    upper? = text == String.upcase(text) and Regex.match?(~r/\p{Lu}/u, text)

    cond do
      indent >= 32 and upper? and String.ends_with?(text, ":") -> :transition
      indent >= 32 -> :right
      indent >= 18 and upper? -> :character
      indent >= 18 -> :centered
      indent >= 13 and String.starts_with?(text, "(") -> :parenthetical
      indent >= 6 -> :dialogue
      upper? and Regex.match?(@scene_re, strip_scene_numbers(text)) -> :scene
      # At the margin only "... TO:" reads back as a transition in Fountain;
      # "FADE IN:" and the like stay as written.
      upper? and String.ends_with?(text, "TO:") -> :transition
      true -> :action
    end
  end

  # Joins wrapped lines into paragraphs and speeches into blocks:
  # [{:scene | :action | :transition | :centered, text} | {:speech, cue, [{:paren | :line, text}]}]
  defp merge(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      tight = line.gap < 1.6

      case {line.kind, acc} do
        {:action, [{:action, text} | rest]} when tight ->
          [{:action, text <> " " <> line.text} | rest]

        {:dialogue, [{:speech, cue, [{:line, t} | parts]} | rest]} ->
          [{:speech, cue, [{:line, t <> " " <> line.text} | parts]} | rest]

        {:dialogue, [{:speech, cue, parts} | rest]} ->
          [{:speech, cue, [{:line, line.text} | parts]} | rest]

        {:parenthetical, [{:speech, cue, [{:paren, t} | parts]} | rest]} ->
          # A parenthetical that has not closed yet wraps onto this line.
          if String.ends_with?(t, ")"),
            do: [{:speech, cue, [{:paren, line.text}, {:paren, t} | parts]} | rest],
            else: [{:speech, cue, [{:paren, t <> " " <> line.text} | parts]} | rest]

        {:parenthetical, [{:speech, cue, parts} | rest]} ->
          [{:speech, cue, [{:paren, line.text} | parts]} | rest]

        {:character, [{:speech, prev, _} | _]} ->
          # A speech carried over a page break repeats its cue with CONT'D.
          if continued?(line.text, prev),
            do: acc,
            else: [{:speech, line.text, []} | acc]

        {:character, _} ->
          [{:speech, line.text, []} | acc]

        {:dialogue, _} ->
          # Dialogue without a cue (a cue lost at a page top): keep the words.
          [{:action, line.text} | acc]

        {:parenthetical, _} ->
          [{:action, line.text} | acc]

        {:right, _} ->
          [{:transition, line.text} | acc]

        {kind, _} ->
          [{kind, line.text} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn
      {:speech, cue, parts} -> {:speech, cue, Enum.reverse(parts)}
      other -> other
    end)
    |> Enum.reject(&match?({:speech, _, []}, &1))
  end

  defp continued?(cue, prev) do
    base = fn c ->
      c |> String.replace(~r/\s*\((CONT'?D|CONTINUED|CONT)\)\s*/i, "") |> String.trim()
    end

    Regex.match?(~r/\(CONT'?D\)|\(CONTINUED\)/i, cue) and base.(cue) == base.(prev)
  end

  ## Fountain

  defp render({:scene, text}) do
    case Regex.run(~r/^(\d+[A-Z]?)\s+(.*?)(?:\s+\1)?$/, text) do
      [_, number, heading] -> "#{force(heading)} ##{number}#"
      nil -> force(text)
    end
  end

  defp render({:action, text}) do
    # An all-capitals action line on its own would read as a cue; force it.
    if text == String.upcase(text) and Regex.match?(~r/\p{Lu}/u, text) and
         String.length(text) < 40,
       do: "!" <> text,
       else: text
  end

  defp render({:transition, text}) do
    if String.ends_with?(text, "TO:"), do: text, else: "> " <> text
  end

  defp render({:centered, text}), do: "> #{text} <"

  defp render({:speech, cue, parts}) do
    lines = Enum.map(parts, fn {_kind, text} -> text end)
    cue = if Regex.match?(@scene_re, cue), do: "@" <> cue, else: cue
    Enum.join([cue | lines], "\n")
  end

  defp force(heading) do
    if Regex.match?(@scene_re, heading), do: heading, else: "." <> heading
  end

  defp strip_scene_numbers(text),
    do: String.replace(text, ~r/^\d+[A-Z]?\s+/, "")

  ## Title page

  # A first page with no scene heading and no dialogue is a title page: the
  # first line is the title, a "by" line the credit, the next the author,
  # and what sits low on the left the contact.
  defp title_page([first | rest] = pages) do
    scene? = fn line -> Regex.match?(@scene_re, strip_scene_numbers(line.text)) end

    # Only ever the first of several pages, short, and with no scene on it.
    if rest != [] and first != [] and not Enum.any?(first, scene?) and length(first) <= 15 do
      [title | others] = first
      {by, others} = Enum.split_with(others, &Regex.match?(~r/^(written )?by\b/i, &1.text))
      {author, others} = if by != [], do: Enum.split(others, 1), else: {[], others}
      mid = (title.y + Enum.min_by(first, & &1.y).y) / 2
      contact = Enum.filter(others, &(&1.y < mid))

      keys =
        [
          {"Title", [title.text]},
          {"Credit", Enum.map(by, & &1.text)},
          {"Author", Enum.map(author, & &1.text)},
          {"Contact", Enum.map(contact, & &1.text)}
        ]
        |> Enum.reject(fn {_k, v} -> v == [] end)
        |> Enum.map_join("\n", fn
          {key, [one]} -> "#{key}: #{one}"
          {key, many} -> "#{key}:\n" <> Enum.map_join(many, "\n", &("    " <> &1))
        end)

      {keys <> "\n\n", rest}
    else
      {"", pages}
    end
  end

  defp title_page([]), do: {"", []}
end
