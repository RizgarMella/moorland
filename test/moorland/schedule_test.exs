defmodule Moorland.Scripts.ScheduleTest do
  use ExUnit.Case, async: true

  alias Moorland.Scripts.Schedule

  @script """
  INT. KITCHEN - DAY

  ANNA
  Morning.

  BEN
  Is it?

  EXT. GARDEN - NIGHT

  ANNA
  Look at the stars.

  INT. KITCHEN - DAY

  BEN
  Coffee?
  """

  defp item(attrs) do
    Map.merge(%{id: System.unique_integer([:positive]), line_no: 0, heading: nil}, attrs)
  end

  defp strip(position, heading, line),
    do: item(%{kind: "scene", position: position, heading: heading, line_no: line})

  defp day(position), do: item(%{kind: "day", position: position})

  test "matches strips to scenes and leaves the rest unscheduled" do
    board = Schedule.build(@script, [], [strip(0, "EXT. GARDEN - NIGHT", 8)])

    assert [%{kind: :strip, scene: %{number: 2}}] = board.rows
    assert Enum.map(board.unscheduled, & &1.number) == [1, 3]
  end

  test "two strips with the same heading keep the scene nearest their line" do
    late = strip(0, "INT. KITCHEN - DAY", 13)
    early = strip(1, "INT. KITCHEN - DAY", 0)
    board = Schedule.build(@script, [], [late, early])

    assert [%{scene: %{number: 3}}, %{scene: %{number: 1}}] = board.rows
    assert board.unscheduled |> Enum.map(& &1.number) == [2]
  end

  test "a rewritten heading keeps its strip by location" do
    rewritten = String.replace(@script, "EXT. GARDEN - NIGHT", "EXT. GARDEN - DAWN")
    board = Schedule.build(rewritten, [], [strip(0, "EXT. GARDEN - NIGHT", 8)])

    assert [%{kind: :strip, scene: %{heading: "EXT. GARDEN - DAWN"}}] = board.rows
  end

  test "a strip whose scene is gone is reported missing" do
    board = Schedule.build(@script, [], [strip(0, "INT. ATTIC - NIGHT", 4)])
    assert [%{kind: :missing}] = board.rows
    assert length(board.unscheduled) == 3
  end

  test "day breaks close days with their page and scene totals" do
    items = [
      strip(0, "INT. KITCHEN - DAY", 0),
      strip(1, "EXT. GARDEN - NIGHT", 8),
      day(2),
      strip(3, "INT. KITCHEN - DAY", 13)
    ]

    board = Schedule.build(@script, [], items)

    assert [_, _, %{kind: :day, day: 1, scenes: 2, eighths: e1}, _] = board.rows
    [s1, s2, s3] = stats_scenes()
    assert e1 == s1.eighths + s2.eighths
    assert board.open_day == %{day: 2, scenes: 1, eighths: s3.eighths}
    assert board.days == 1
    assert board.unscheduled == []
    assert board.unscheduled_eighths == 0
  end

  test "numbers cast by size of part, then silent tagged cast" do
    tagged = %{
      id: 1,
      category: "cast",
      name: "Postman",
      anchor_text: nil,
      line_no: 8,
      author: nil
    }

    board = Schedule.build(@script, [tagged], [strip(0, "EXT. GARDEN - NIGHT", 8)])

    assert board.cast == [{1, "ANNA"}, {2, "BEN"}, {3, "POSTMAN"}]
    assert [%{cast: [1, 3]}] = board.rows
    assert [%{number: 1, cast_ids: [1, 2]}, %{number: 3, cast_ids: [2]}] = board.unscheduled
  end

  defp stats_scenes, do: Moorland.Scripts.Stats.scenes(@script)
end
