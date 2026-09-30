defmodule Moorland.ScheduleContextTest do
  use Moorland.DataCase

  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts

  @content """
  INT. KITCHEN - DAY

  Toast.

  EXT. GARDEN - NIGHT

  Stars.

  INT. ATTIC - DAY

  Dust.
  """

  setup do
    owner = Scope.for_user(user_fixture())
    other_user = user_fixture()
    {:ok, script} = Scripts.create_script(owner, %{title: "House"})
    {:ok, script} = Scripts.save_content(owner, script, @content)
    %{owner: owner, other: Scope.for_user(other_user), other_user: other_user, script: script}
  end

  defp kinds(script),
    do: script |> Scripts.list_schedule_items() |> Enum.map(&(&1.heading || "DAY"))

  test "schedules scenes and day breaks in order", %{owner: owner, script: s} do
    {:ok, _} = Scripts.schedule_scene(owner, s, %{heading: "EXT. GARDEN - NIGHT", line_no: 4})
    {:ok, day} = Scripts.add_day_break(owner, s)

    {:ok, _} =
      Scripts.schedule_scene(owner, s, %{"heading" => "INT. KITCHEN - DAY", "line_no" => "0"})

    assert kinds(s) == ["EXT. GARDEN - NIGHT", "DAY", "INT. KITCHEN - DAY"]
    assert day.kind == "day"
  end

  test "schedules every remaining scene in script order", %{owner: owner, script: s} do
    {:ok, _} = Scripts.schedule_scene(owner, s, %{heading: "EXT. GARDEN - NIGHT", line_no: 4})
    assert {:ok, 2} = Scripts.schedule_remaining(owner, s)

    assert kinds(s) == ["EXT. GARDEN - NIGHT", "INT. KITCHEN - DAY", "INT. ATTIC - DAY"]
    assert {:ok, 0} = Scripts.schedule_remaining(owner, s)
  end

  test "reorders, places dragged-on scenes and keeps unlisted items", %{owner: owner, script: s} do
    {:ok, a} = Scripts.schedule_scene(owner, s, %{heading: "INT. KITCHEN - DAY", line_no: 0})
    {:ok, d} = Scripts.add_day_break(owner, s)
    {:ok, b} = Scripts.schedule_scene(owner, s, %{heading: "EXT. GARDEN - NIGHT", line_no: 4})

    # A stale client that never saw `a` sends only part of the board.
    :ok =
      Scripts.reorder_schedule(owner, s, [
        to_string(b.id),
        %{"heading" => "INT. ATTIC - DAY", "line_no" => 8},
        d.id,
        "999999",
        %{"heading" => 5},
        %{"heading" => ""},
        [1, 2],
        nil
      ])

    assert kinds(s) == ["EXT. GARDEN - NIGHT", "INT. ATTIC - DAY", "DAY", "INT. KITCHEN - DAY"]
    assert [0, 1, 2, 3] = s |> Scripts.list_schedule_items() |> Enum.map(& &1.position)
    assert Enum.find(Scripts.list_schedule_items(s), &(&1.id == a.id)).position == 3
  end

  test "sets a day's date and note, and only on day breaks", %{owner: owner, script: s} do
    {:ok, day} = Scripts.add_day_break(owner, s)
    {:ok, strip} = Scripts.schedule_scene(owner, s, %{heading: "INT. KITCHEN - DAY", line_no: 0})

    assert {:ok, updated} =
             Scripts.update_day_break(owner, s, day.id, %{
               "shoot_date" => "2026-10-12",
               "note" => "  Unit move at lunch  "
             })

    assert updated.shoot_date == ~D[2026-10-12] and updated.note == "Unit move at lunch"
    assert {:ok, %{note: nil}} = Scripts.update_day_break(owner, s, day.id, %{"note" => ""})
    assert {:error, :not_found} = Scripts.update_day_break(owner, s, strip.id, %{"note" => "x"})
  end

  test "removes items, but not another script's", %{owner: owner, script: s} do
    {:ok, strip} = Scripts.schedule_scene(owner, s, %{heading: "INT. KITCHEN - DAY", line_no: 0})
    {:ok, other} = Scripts.create_script(owner, %{title: "Elsewhere"})
    {:ok, theirs} = Scripts.add_day_break(owner, other)

    assert {:error, :not_found} = Scripts.remove_schedule_item(owner, s, theirs.id)
    assert :ok = Scripts.remove_schedule_item(owner, s, strip.id)
    assert Scripts.list_schedule_items(s) == []
  end

  test "only editors change the schedule", ctx do
    %{owner: owner, other: other, other_user: other_user, script: s} = ctx
    {:ok, _} = Scripts.add_collaborator(owner, s, other_user.email, "commenter")
    {:ok, strip} = Scripts.schedule_scene(owner, s, %{heading: "INT. KITCHEN - DAY", line_no: 0})

    assert {:error, :not_allowed} =
             Scripts.schedule_scene(other, s, %{heading: "INT. ATTIC - DAY", line_no: 8})

    assert {:error, :not_allowed} = Scripts.add_day_break(other, s)
    assert {:error, :not_allowed} = Scripts.schedule_remaining(other, s)
    assert {:error, :not_allowed} = Scripts.reorder_schedule(other, s, [])
    assert {:error, :not_allowed} = Scripts.remove_schedule_item(other, s, strip.id)
  end

  test "changes are broadcast", %{owner: owner, script: s} do
    Scripts.subscribe(s.id)
    {:ok, _} = Scripts.add_day_break(owner, s)
    sid = s.id
    assert_receive {:schedule_changed, ^sid}
  end
end
