defmodule Moorland.Scripts.Schedule do
  @moduledoc """
  The stripboard as pure functions over the script text, its breakdown tags
  and its schedule items.

  A scene strip remembers the heading it was made from and the line it was
  on. Each time, strips are matched to the current scenes: first a scene
  with the same heading nearest the remembered line, then (for a heading
  that was rewritten, say DAY to NIGHT) a scene at the same location. Each
  scene is claimed by at most one strip; a strip that finds no scene is
  reported as missing, and scenes no strip claims are unscheduled.

  Cast are numbered for the strips the way a production numbers them: by
  size of part (words of dialogue), then anyone tagged as cast without
  lines, alphabetically.
  """

  alias Moorland.Scripts.{Breakdown, BreakdownTag, Stats}

  @doc """
  Builds the board. Returns `%{rows, unscheduled, cast, days, scheduled_eighths,
  unscheduled_eighths}` where rows, in board order, are:

    * `%{kind: :strip, item, scene, cast}` - `cast` is the scene's cast numbers
    * `%{kind: :missing, item}` - a strip whose scene has gone
    * `%{kind: :day, item, day, eighths, scenes}` - an end-of-day break with
      the day's totals

  Strips after the last break form `:open_day` (`%{day, eighths, scenes}`),
  or it is nil. `cast` is `[{number, name}]`. `shoot_days` lists every day
  with strips on it, the open one included, as
  `%{day, date, note, scenes, eighths, cast}` where `scenes` are the scene
  maps in board order and `cast` the numbers working that day.
  """
  def build(text, tags, items) do
    breakdown = Breakdown.build(text, tags)
    scenes = breakdown.scenes
    cast_ids = cast_numbers(text, scenes)

    items = Enum.sort_by(items, &{&1.position, &1.id})
    matches = match(items, scenes)

    {rows, day, acc} =
      Enum.reduce(items, {[], 1, %{eighths: 0, scenes: 0}}, fn item, {rows, day, acc} ->
        case {item.kind, Map.get(matches, item.id)} do
          {"day", _} ->
            row = %{kind: :day, item: item, day: day, eighths: acc.eighths, scenes: acc.scenes}
            {[row | rows], day + 1, %{eighths: 0, scenes: 0}}

          {"scene", nil} ->
            {[%{kind: :missing, item: item} | rows], day, acc}

          {"scene", scene} ->
            row = %{kind: :strip, item: item, scene: scene, cast: scene_cast(scene, cast_ids)}
            {[row | rows], day, %{eighths: acc.eighths + scene.eighths, scenes: acc.scenes + 1}}
        end
      end)

    claimed = matches |> Map.values() |> MapSet.new(& &1.number)
    unscheduled = Enum.reject(scenes, &MapSet.member?(claimed, &1.number))
    scheduled = Enum.filter(scenes, &MapSet.member?(claimed, &1.number))

    rows = Enum.reverse(rows)

    %{
      rows: rows,
      shoot_days: shoot_days(rows),
      open_day: if(acc.scenes > 0, do: Map.put(acc, :day, day)),
      unscheduled: Enum.map(unscheduled, &Map.put(&1, :cast_ids, scene_cast(&1, cast_ids))),
      cast: cast_ids |> Enum.map(fn {name, n} -> {n, name} end) |> Enum.sort(),
      days: Enum.count(items, &(&1.kind == "day")),
      scheduled_eighths: sum_eighths(scheduled),
      unscheduled_eighths: sum_eighths(unscheduled)
    }
  end

  @doc """
  Day out of days: for each cast member, what they do on each shoot day.
  Codes follow the production standard - `"SW"` start work, `"W"` work,
  `"WF"` work finish, `"SWF"` a single day, `"H"` held between work days,
  `nil` not yet started or already finished. Returns
  `%{days, cast: [%{number, name, codes, work, hold, start, finish}]}`
  where `start` and `finish` are day numbers.
  """
  def day_out_of_days(%{shoot_days: days, cast: cast}) do
    rows =
      for {number, name} <- cast do
        working = for d <- days, number in d.cast, do: d.day

        case working do
          [] ->
            nil

          [first | _] ->
            last = List.last(working)

            codes =
              Enum.map(days, fn %{day: day} ->
                cond do
                  day == first and day == last -> "SWF"
                  day == first -> "SW"
                  day == last -> "WF"
                  day in working -> "W"
                  day > first and day < last -> "H"
                  true -> nil
                end
              end)

            %{
              number: number,
              name: name,
              codes: codes,
              work: length(working),
              hold: Enum.count(codes, &(&1 == "H")),
              start: first,
              finish: last
            }
        end
      end

    %{days: days, cast: Enum.reject(rows, &is_nil/1)}
  end

  # Days are numbered as the board numbers its breaks; a day with no strips
  # (two breaks in a row) keeps its number but is left out.
  @doc """
  Everything a call sheet for shoot day `day` needs, or nil if there is no
  such day: the day (`item` is its end-of-day break, nil for the open day),
  its place in the shoot (`index` of `total`), the cast called or held
  with their day-out-of-days code, each department's elements for the
  day's scenes with the scenes they are in, and the next day's scenes for
  the advance schedule.
  """
  def call_sheet(%{shoot_days: days} = board, day) do
    case Enum.find_index(days, &(&1.day == day)) do
      nil ->
        nil

      index ->
        this = Enum.at(days, index)

        cast =
          for row <- day_out_of_days(board).cast,
              code = Enum.at(row.codes, index),
              code != nil,
              do: %{number: row.number, name: row.name, code: code}

        %{
          day: this,
          index: index + 1,
          total: length(days),
          prev: if(index > 0, do: Enum.at(days, index - 1)),
          next: Enum.at(days, index + 1),
          cast: cast,
          departments: departments(this.scenes)
        }
    end
  end

  defp departments(scenes) do
    for {category, _label} <- BreakdownTag.categories(), category != "cast" do
      elements =
        scenes
        |> Enum.flat_map(fn scene ->
          scene.elements
          |> Map.get(category, [])
          |> Enum.map(&{&1, Map.take(scene, [:number, :label])})
        end)
        |> Enum.group_by(fn {entry, _n} -> entry.key end)
        |> Enum.map(fn {_key, [{first, _} | _] = rows} ->
          %{name: first.name, scenes: rows |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}
        end)
        |> Enum.sort_by(&String.downcase(&1.name))

      {category, elements}
    end
    |> Enum.reject(fn {_category, elements} -> elements == [] end)
  end

  defp shoot_days(rows) do
    {days, open, day} =
      Enum.reduce(rows, {[], [], 1}, fn
        %{kind: :strip} = row, {days, open, day} ->
          {days, [row | open], day}

        %{kind: :day, item: item}, {days, open, day} ->
          {[new_day(day, item, open) | days], [], day + 1}

        _missing, acc ->
          acc
      end)

    [new_day(day, nil, open) | days]
    |> Enum.reverse()
    |> Enum.reject(&(&1.scenes == []))
  end

  defp new_day(day, item, strips) do
    strips = Enum.reverse(strips)

    %{
      day: day,
      item: item,
      date: item && item.shoot_date,
      note: item && item.note,
      scenes: Enum.map(strips, & &1.scene),
      eighths: strips |> Enum.map(& &1.scene.eighths) |> Enum.sum(),
      cast: strips |> Enum.flat_map(& &1.cast) |> Enum.uniq() |> Enum.sort()
    }
  end

  @doc """
  Matches scene items to scenes: `%{item_id => scene}`. Exact headings are
  claimed first, nearest the remembered line; then remaining items claim a
  remaining scene at the same location.
  """
  def match(items, scenes) do
    items = Enum.filter(items, &(&1.kind == "scene"))

    {matches, taken} = claim(items, scenes, %{}, MapSet.new(), &same_heading?/2)
    {matches, _taken} = claim(items, scenes, matches, taken, &same_location?/2)
    matches
  end

  # Candidate pairs are claimed closest first, so two strips for two
  # identical headings each keep the scene nearest where they were.
  defp claim(items, scenes, matches, taken, fits?) do
    items
    |> Enum.reject(&Map.has_key?(matches, &1.id))
    |> Enum.flat_map(fn item ->
      for scene <- scenes, not MapSet.member?(taken, scene.number), fits?.(item, scene) do
        {abs(scene.line - item.line_no), item, scene}
      end
    end)
    |> Enum.sort_by(fn {dist, item, scene} -> {dist, item.position, scene.line} end)
    |> Enum.reduce({matches, taken}, fn {_dist, item, scene}, {matches, taken} ->
      if Map.has_key?(matches, item.id) or MapSet.member?(taken, scene.number),
        do: {matches, taken},
        else: {Map.put(matches, item.id, scene), MapSet.put(taken, scene.number)}
    end)
  end

  defp same_heading?(item, scene),
    do: Breakdown.normalize(item.heading) == Breakdown.normalize(scene.heading)

  defp same_location?(item, scene) do
    location = item.heading |> to_string() |> String.upcase() |> Stats.location()
    location != "" and Breakdown.normalize(location) == Breakdown.normalize(scene.location)
  end

  # name => number, speaking parts by size, then silent tagged cast.
  defp cast_numbers(text, scenes) do
    speaking = text |> Stats.compute() |> Map.fetch!(:characters) |> Enum.map(& &1.name)

    tagged =
      scenes
      |> Enum.flat_map(fn scene -> Map.get(scene.elements, "cast", []) end)
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in speaking))
      |> Enum.sort()

    (speaking ++ tagged)
    |> Enum.with_index(1)
    |> Map.new()
  end

  defp scene_cast(scene, cast_ids) do
    scene.elements
    |> Map.get("cast", [])
    |> Enum.map(&Map.get(cast_ids, &1.name))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp sum_eighths(scenes), do: scenes |> Enum.map(& &1.eighths) |> Enum.sum()
end
