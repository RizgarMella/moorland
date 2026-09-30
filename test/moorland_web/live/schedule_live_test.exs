defmodule MoorlandWeb.ScheduleLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts

  @content """
  INT. KITCHEN - DAY

  ANNA
  Morning.

  EXT. GARDEN - NIGHT

  BEN
  Stars.

  INT. ATTIC - NIGHT

  Dust.
  """

  setup %{conn: conn} do
    user = user_fixture()
    scope = Scope.for_user(user)
    {:ok, script} = Scripts.create_script(scope, %{title: "House"})
    {:ok, script} = Scripts.save_content(scope, script, @content)
    %{conn: log_in_user(conn, user), scope: scope, script: script}
  end

  defp strip_ids(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#board > [data-id]")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))
  end

  test "starts with every scene unscheduled", %{conn: conn, script: script} do
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/schedule")

    assert has_element?(lv, "#board-empty")
    assert has_element?(lv, "#unscheduled-1.strip-int-day", "INT. KITCHEN - DAY")
    assert has_element?(lv, "#unscheduled-2.strip-ext-night")
    assert has_element?(lv, "#unscheduled-3.strip-int-night")
    assert has_element?(lv, "#cast-list", "ANNA")
  end

  test "schedules scenes, closes days and totals them", %{conn: conn, script: script} do
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/schedule")

    lv |> element("#unscheduled-2 button[phx-click=schedule_scene]") |> render_click()
    assert has_element?(lv, "#board .strip-ext-night", "GARDEN")
    refute has_element?(lv, "#unscheduled-2")

    lv |> element("#add-day") |> render_click()
    assert has_element?(lv, "#board", "End of day 1")

    lv |> element("#schedule-remaining") |> render_click()
    refute has_element?(lv, "#unscheduled [draggable]")
    assert has_element?(lv, "#open-day", "Day 2 so far")
    assert has_element?(lv, "#schedule-summary", "2")
  end

  test "drag order and arrows reorder the board", %{conn: conn, scope: scope, script: script} do
    {:ok, a} = Scripts.schedule_scene(scope, script, %{heading: "INT. KITCHEN - DAY", line_no: 0})

    {:ok, b} =
      Scripts.schedule_scene(scope, script, %{heading: "EXT. GARDEN - NIGHT", line_no: 5})

    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/schedule")

    assert strip_ids(lv) == ["strip-#{a.id}", "strip-#{b.id}"]

    render_hook(lv, "reorder", %{
      "order" => [
        to_string(b.id),
        %{"heading" => "INT. ATTIC - NIGHT", "line_no" => 10},
        to_string(a.id)
      ]
    })

    [first, attic, last] = strip_ids(lv)
    assert first == "strip-#{b.id}" and last == "strip-#{a.id}"
    assert has_element?(lv, "##{attic}", "ATTIC")

    lv |> element("#strip-#{a.id} button[phx-value-by='-1']") |> render_click()
    assert Enum.at(strip_ids(lv), 1) == "strip-#{a.id}"
  end

  test "sets a day's date and note", %{conn: conn, scope: scope, script: script} do
    {:ok, day} = Scripts.add_day_break(scope, script)
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/schedule")

    lv
    |> form("#day-form-#{day.id}", %{"shoot_date" => "2026-10-12", "note" => "Night shoot"})
    |> render_change()

    assert [%{shoot_date: ~D[2026-10-12], note: "Night shoot"}] =
             Scripts.list_schedule_items(script)
  end

  test "flags strips whose scene was cut", %{conn: conn, scope: scope, script: script} do
    {:ok, _} =
      Scripts.schedule_scene(scope, script, %{heading: "INT. ATTIC - NIGHT", line_no: 10})

    cut = String.replace(@content, "INT. ATTIC - NIGHT\n\nDust.\n", "")
    {:ok, _} = Scripts.save_content(scope, script, cut, script.content_version)

    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/schedule")
    assert has_element?(lv, "#board", "No longer in the script")
  end

  test "commenters see the board read-only", %{scope: scope, script: script} do
    {:ok, _} = Scripts.schedule_scene(scope, script, %{heading: "INT. KITCHEN - DAY", line_no: 0})
    commenter = user_fixture()
    {:ok, _} = Scripts.add_collaborator(scope, script, commenter.email, "commenter")

    {:ok, lv, _html} =
      build_conn() |> log_in_user(commenter) |> live(~p"/scripts/#{script.id}/schedule")

    assert has_element?(lv, "#board .strip", "KITCHEN")
    refute has_element?(lv, "#add-day")
    assert has_element?(lv, "#board[data-can-edit=false]")
    refute has_element?(lv, "[draggable=true]")
    refute has_element?(lv, "button[phx-click=remove_item]")

    render_hook(lv, "add_day", %{})
    assert Scripts.list_schedule_items(script) |> length() == 1
  end
end
