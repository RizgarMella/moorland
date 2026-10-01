defmodule MoorlandWeb.LessonLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts
  alias Moorland.Scripts.{Script, Stats}

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: Scope.for_user(user)}
  end

  test "the template times its parts by narration" do
    stats = Stats.compute_for(%Script{kind: "lesson"}, Script.template("lesson"))
    assert %{lesson: true, podcast: false} = stats
    assert Enum.map(stats.segments, & &1.title) == ["Hook", "The parts", "Recap"]
    assert stats.seconds > 0
    assert [%{name: "NARRATOR"}] = stats.characters
  end

  test "a lesson starts from the template and keeps shoot tools away", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/scripts")

    lv
    |> form("#create-script-form", %{"title" => "Lighthouses 101", "kind" => "lesson"})
    |> render_submit()

    [lesson] = Scripts.list_scripts(scope)
    assert lesson.kind == "lesson" and lesson.content =~ "Objectives:"

    {:ok, lv, _html} = live(conn, ~p"/scripts/#{lesson.id}")
    assert has_element?(lv, "#editor-root[data-kind=lesson][data-can-lock-pages=false]")
    refute has_element?(lv, "button[phx-value-panel=breakdown]")
    refute has_element?(lv, "button[phx-value-format=sides]")

    lv |> element("button[phx-value-panel=reports]") |> render_click()
    assert has_element?(lv, "#podcast-segments", "Parts")
    assert render(lv) =~ "voices"
  end
end
