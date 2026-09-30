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
    Map.merge(
      %{
        id: System.unique_integer([:positive]),
        line_no: 0,
        heading: nil,
        shoot_date: nil,
        note: nil
      },
      attrs
    )
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

  describe "shoot days and day out of days" do
    @dood """
    INT. ONE - DAY

    ANNA
    One.

    INT. TWO - DAY

    BEN
    Two.

    INT. THREE - DAY

    ANNA
    Three.

    BEN
    Three.

    INT. FOUR - DAY

    CARL
    Four.
    """

    defp dood_board, do: Schedule.build(@dood, [], dood_board_items())

    defp dood_board_items do
      [
        strip(0, "INT. ONE - DAY", 0),
        item(%{kind: "day", position: 1, shoot_date: ~D[2026-10-12], note: "Stage 2"}),
        strip(2, "INT. TWO - DAY", 5),
        day(3),
        day(4),
        strip(5, "INT. THREE - DAY", 10),
        day(6),
        strip(7, "INT. FOUR - DAY", 18)
      ]
    end

    test "lists each day with its scenes, cast and page total" do
      days = dood_board().shoot_days

      assert Enum.map(days, & &1.day) == [1, 2, 4, 5]
      assert [%{date: ~D[2026-10-12], note: "Stage 2", scenes: [%{number: 1}]} | _] = days
      assert List.last(days).date == nil
      assert Enum.at(days, 2).cast == [1, 2]
    end

    test "codes each cast member's days" do
      %{cast: rows} = Schedule.day_out_of_days(dood_board())
      by_name = Map.new(rows, &{&1.name, &1})

      # ANNA works days 1 and 4, held between; BEN works 2 and 4; CARL only 5.
      assert by_name["ANNA"].codes == ["SW", "H", "WF", nil]
      assert %{work: 2, hold: 1, start: 1, finish: 4} = by_name["ANNA"]
      assert by_name["BEN"].codes == [nil, "SW", "WF", nil]
      assert by_name["CARL"].codes == [nil, nil, nil, "SWF"]
      assert %{work: 1, hold: 0} = by_name["CARL"]
    end

    test "builds a day's call sheet with held cast and the advance schedule" do
      prop = %{
        id: 1,
        category: "props",
        name: "Kettle",
        anchor_text: "Three",
        line_no: 12,
        author: nil
      }

      board = Schedule.build(@dood, [prop], dood_board_items())
      sheet = Schedule.call_sheet(board, 2)

      assert %{index: 2, total: 4, day: %{day: 2}, next: %{day: 4}, prev: %{day: 1}} = sheet
      assert Enum.map(sheet.cast, &{&1.name, &1.code}) == [{"ANNA", "H"}, {"BEN", "SW"}]
      assert sheet.departments == []

      assert [{"props", [%{name: "Kettle", scenes: [%{number: 3, label: "3"}]}]}] =
               Schedule.call_sheet(board, 4).departments

      assert Schedule.call_sheet(board, 3) == nil
      assert Schedule.call_sheet(board, 5).next == nil
    end

    test "leaves out cast who are not on the board" do
      board = Schedule.build(@dood, [], [strip(0, "INT. FOUR - DAY", 18)])
      assert [%{name: "CARL", codes: ["SWF"]}] = Schedule.day_out_of_days(board).cast
    end
  end
end
