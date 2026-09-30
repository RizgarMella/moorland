defmodule MoorlandWeb.CallSheetLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Contacts
  alias Moorland.Scripts

  @content """
  INT. KITCHEN - DAY

  = Anna burns the toast.

  ANNA
  Morning.

  EXT. GARDEN - NIGHT

  BEN
  Stars.

  INT. ATTIC - NIGHT

  ANNA
  Dust.
  """

  setup %{conn: conn} do
    user = user_fixture()
    scope = Scope.for_user(user)
    {:ok, script} = Scripts.create_script(scope, %{title: "House"})
    {:ok, script} = Scripts.save_content(scope, script, @content)

    {:ok, _} = Scripts.schedule_scene(scope, script, %{heading: "INT. KITCHEN - DAY", line_no: 0})
    {:ok, day1} = Scripts.add_day_break(scope, script, %{shoot_date: ~D[2026-10-12]})

    {:ok, _} =
      Scripts.schedule_scene(scope, script, %{heading: "EXT. GARDEN - NIGHT", line_no: 7})

    {:ok, _day2} = Scripts.add_day_break(scope, script)

    {:ok, _} =
      Scripts.schedule_scene(scope, script, %{heading: "INT. ATTIC - NIGHT", line_no: 12})

    %{conn: log_in_user(conn, user), scope: scope, script: script, day1: day1}
  end

  test "shows the day's scenes, cast and advance schedule", %{conn: conn, script: script} do
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/schedule/day/1")

    assert has_element?(lv, "#call-sheet", "Day 1")
    assert has_element?(lv, "#call-sheet", "Monday 12 October 2026")
    assert has_element?(lv, "#call-scenes", "KITCHEN")
    assert has_element?(lv, "#call-scenes", "Anna burns the toast.")
    assert has_element?(lv, "#call-cast", "ANNA")
    refute has_element?(lv, "#call-cast", "BEN")
    assert has_element?(lv, "#advance-schedule", "EXT. GARDEN - NIGHT")
  end

  test "held cast are listed as held", %{conn: conn, script: script} do
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/schedule/day/2")
    assert has_element?(lv, "#call-cast tr", "Hold")
    assert has_element?(lv, "#call-cast", "BEN")
  end

  test "names the actor from the viewer's contacts", %{conn: conn, scope: scope, script: script} do
    {:ok, _} =
      Contacts.create_contact(scope, %{name: "Jo Bloggs", role: "Anna", phone: "0700 900"})

    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/schedule/day/1")
    assert has_element?(lv, "#call-cast", "Jo Bloggs")
    assert has_element?(lv, "#call-cast", "0700 900")
  end

  test "saves call times and location", %{conn: conn, script: script} do
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/schedule/day/1")

    lv
    |> form("#calls-form", %{
      "crew_call" => "06:30",
      "shooting_call" => "08:00",
      "location" => "12 Mill Lane",
      "cast_calls" => %{"ANNA" => "07:15"}
    })
    |> render_change()

    [day | _] = Scripts.list_schedule_items(script) |> Enum.filter(&(&1.kind == "day"))
    assert %{crew_call: "06:30", shooting_call: "08:00", location: "12 Mill Lane"} = day
    assert day.cast_calls == %{"ANNA" => "07:15"}
  end

  test "rejects times that are not HH:MM", %{scope: scope, script: script, day1: day1} do
    assert {:error, cs} =
             Scripts.update_day_break(scope, script, day1.id, %{"crew_call" => "7am"})

    assert "use 24-hour HH:MM" in Moorland.DataCase.errors_on(cs).crew_call

    {:ok, day} =
      Scripts.update_day_break(scope, script, day1.id, %{
        "cast_calls" => %{"ANNA" => "07:00", "BEN" => "", "X" => "25:00"}
      })

    assert day.cast_calls == %{"ANNA" => "07:00"}
  end

  test "the open last day is read-only", %{conn: conn, script: script} do
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/schedule/day/3")
    assert has_element?(lv, "#call-sheet", "Day 3")
    refute has_element?(lv, "#calls-form input[name=crew_call]")
    refute has_element?(lv, "#advance-schedule")
    assert has_element?(lv, "#prev-day")
    refute has_element?(lv, "#next-day")
  end

  test "a day that doesn't exist says so", %{conn: conn, script: script} do
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/schedule/day/9")
    assert has_element?(lv, "#no-such-day")
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/schedule/day/nope")
    assert has_element?(lv, "#no-such-day")
  end

  test "viewers read the call sheet but cannot change it", %{scope: scope, script: script} do
    viewer = user_fixture()
    {:ok, _} = Scripts.add_collaborator(scope, script, viewer.email, "viewer")

    {:ok, lv, _html} =
      build_conn() |> log_in_user(viewer) |> live(~p"/scripts/#{script.id}/schedule/day/1")

    assert has_element?(lv, "#call-cast", "ANNA")
    refute has_element?(lv, "#calls-form input")
  end

  test "the stripboard links each day to its call sheet", %{conn: conn, script: script} do
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/schedule")
    assert has_element?(lv, ~s|a[href="/scripts/#{script.id}/schedule/day/1"]|)
    assert has_element?(lv, ~s|a[href="/scripts/#{script.id}/schedule/day/3"]|)
  end
end
