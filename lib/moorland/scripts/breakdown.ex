defmodule Moorland.Scripts.Breakdown do
  @moduledoc """
  Script breakdown as pure functions over the script text and its tags.

  A tag remembers the words it was placed on and the line they were on. The
  tag's scene is found fresh from the current text: the nearest line still
  containing those words, then the scene around that line. Tags whose words
  have gone from the script are reported as unplaced rather than dropped.

  Cast and locations are seeded from the text itself: everyone with a line
  in a scene is in its cast, and the heading gives its set. Those rows are
  computed, never stored, so they are always current.
  """

  alias Moorland.Scripts.{BreakdownTag, Stats}

  @doc """
  Scene sheets for the whole script: each scene from `Stats.scenes/1` with
  `:elements`, a map of category => sorted list of element entries
  (`%{name, key, tags, auto}`), plus `:unplaced` tags.
  """
  def build(text, tags) do
    scenes = Stats.scenes(text)
    lines = normalized_lines(text)

    {placed, unplaced} =
      Enum.reduce(tags, {%{}, []}, fn tag, {placed, unplaced} ->
        with line when is_integer(line) <- locate(lines, tag),
             %{number: number} <- scene_at(scenes, line) do
          {Map.update(placed, number, [tag], &[tag | &1]), unplaced}
        else
          _ -> {placed, [tag | unplaced]}
        end
      end)

    sheets =
      Enum.map(scenes, fn scene ->
        Map.put(scene, :elements, elements_for(scene, Map.get(placed, scene.number, [])))
      end)

    %{scenes: sheets, unplaced: Enum.sort_by(unplaced, &{&1.category, &1.name})}
  end

  @doc """
  The department view: for every category, each element with the scene
  numbers it appears in, from the `:scenes` of `build/2`.
  """
  def departments(%{scenes: scenes}) do
    for {category, _label} <- BreakdownTag.categories() do
      elements =
        scenes
        |> Enum.flat_map(fn scene ->
          scene.elements
          |> Map.get(category, [])
          |> Enum.map(&{&1, scene.number})
        end)
        |> Enum.group_by(fn {entry, _n} -> entry.key end)
        |> Enum.map(fn {key, [{first, _} | _] = rows} ->
          %{
            key: key,
            name: first.name,
            tagged: Enum.any?(rows, fn {entry, _n} -> entry.tags != [] end),
            scenes: rows |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
          }
        end)
        |> Enum.sort_by(&{-length(&1.scenes), &1.key})

      {category, elements}
    end
  end

  @doc "The scene containing a 0-based source line, or nil before the first."
  def scene_at(scenes, line) do
    scenes
    |> Enum.take_while(&(&1.line <= line))
    |> List.last()
  end

  @doc """
  The source line a tag sits on now: its recorded line if the words are still
  there, else the nearest line that has them (earlier wins a tie), else nil.
  A tag with no words keeps its recorded line.
  """
  def locate(lines, %{anchor_text: anchor, line_no: line_no}) do
    needle = padded(anchor)

    cond do
      needle == "  " ->
        if line_no < tuple_size(lines), do: line_no, else: nil

      line_no < tuple_size(lines) and String.contains?(elem(lines, line_no), needle) ->
        line_no

      true ->
        lines
        |> Tuple.to_list()
        |> Enum.with_index()
        |> Enum.filter(fn {line, _i} -> String.contains?(line, needle) end)
        |> Enum.min_by(fn {_line, i} -> {abs(i - line_no), i} end, fn -> nil end)
        |> case do
          {_line, i} -> i
          nil -> nil
        end
    end
  end

  @doc """
  Trims words selected in the rendered preview down to what is actually on
  the source line, so markup the preview hides (`*bold*`, a forced `!`) or a
  selection running onto the next line still anchors. Returns the longest
  leading run of words found on the line, or nil if none is.
  """
  def fit_anchor(text, line_no, selection) do
    lines = normalized_lines(text)
    line = if line_no < tuple_size(lines), do: elem(lines, line_no), else: ""
    words = selection |> to_string() |> String.split(~r/\s+/, trim: true)

    Enum.reduce_while(length(words)..1//-1, nil, fn n, _ ->
      candidate = words |> Enum.take(n) |> Enum.join(" ")
      needle = padded(candidate)

      if needle != "  " and String.contains?(line, needle),
        do: {:halt, candidate},
        else: {:cont, nil}
    end)
  end

  @doc "Case-, punctuation- and markup-blind form used for matching."
  def normalize(nil), do: ""

  def normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  @doc "The key two element names share when they are the same element."
  def element_key(name), do: normalize(name)

  # Lines and needles are padded with spaces so matches fall on whole words.
  defp normalized_lines(text) do
    (text || "")
    |> String.split("\n")
    |> Enum.map(&padded/1)
    |> List.to_tuple()
  end

  defp padded(text), do: " " <> normalize(text) <> " "

  # Tagged elements grouped by category, with the speaking cast seeded in.
  defp elements_for(scene, tags) do
    tagged =
      tags
      |> Enum.group_by(& &1.category)
      |> Map.new(fn {category, tags} ->
        entries =
          tags
          |> Enum.group_by(&element_key(&1.name))
          |> Enum.map(fn {key, [first | _] = group} ->
            %{key: key, name: display_name(category, first.name), tags: group, auto: false}
          end)

        {category, entries}
      end)

    speaking =
      Enum.map(scene.cast, fn name ->
        %{key: element_key(name), name: name, tags: [], auto: true}
      end)

    cast =
      Enum.reduce(Map.get(tagged, "cast", []), speaking, fn entry, acc ->
        case Enum.split_with(acc, &(&1.key == entry.key)) do
          {[auto], rest} -> [%{auto | tags: entry.tags} | rest]
          {[], _} -> acc ++ [entry]
        end
      end)

    tagged
    |> Map.put("cast", cast)
    |> Map.reject(fn {_category, entries} -> entries == [] end)
    |> Map.new(fn {category, entries} -> {category, Enum.sort_by(entries, & &1.key)} end)
  end

  defp display_name("cast", name), do: String.upcase(name)
  defp display_name(_category, name), do: name
end
