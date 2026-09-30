defmodule MoorlandWeb.RevisionLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts
  alias Moorland.Scripts.RevisionSet

  setup %{conn: conn} do
    user = user_fixture()
    scope = Scope.for_user(user)
    {:ok, script} = Scripts.create_script(scope, %{title: "Draft"})
    {:ok, script} = Scripts.save_content(scope, script, "INT. HALL - DAY #1#\n\nA lamp.")
    %{conn: log_in_user(conn, user), scope: scope, script: script}
  end

  test "revision colours follow the production order" do
    assert Enum.map(0..9, &RevisionSet.color_name/1) ==
             ~w(Blue Pink Yellow Green Goldenrod Buff Salmon Cherry) ++
               ["Double Blue", "Double Pink"]

    assert RevisionSet.color_key("Double Pink") == "pink"
  end

  test "starting a revision keeps the saved text as its base", %{scope: scope, script: script} do
    {:ok, blue} = Scripts.start_revision(scope, script)
    {:ok, script} = Scripts.save_content(scope, script, "INT. HALL - DAY #1#\n\nA brass lamp.")
    {:ok, pink} = Scripts.start_revision(scope, script)

    assert blue.color == "Blue" and blue.base_content =~ "A lamp."
    assert pink.color == "Pink" and pink.base_content =~ "A brass lamp."
    assert Enum.map(Scripts.list_revision_sets(script), & &1.color) == ["Blue", "Pink"]
  end

  test "only editors start or end revisions", %{scope: scope, script: script} do
    commenter = user_fixture()
    {:ok, _} = Scripts.add_collaborator(scope, script, commenter.email, "commenter")
    other = Scope.for_user(commenter)

    assert {:error, :not_allowed} = Scripts.start_revision(other, script)
    {:ok, _} = Scripts.start_revision(scope, script)
    assert {:error, :not_allowed} = Scripts.clear_revisions(other, script)
    assert :ok = Scripts.clear_revisions(scope, script)
    assert Scripts.list_revision_sets(script) == []
  end

  test "the editor starts revisions and sends their base to the preview", ctx do
    %{conn: conn, script: script} = ctx
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}")
    assert_push_event(lv, "revision", payload)
    assert payload == %{}
    refute has_element?(lv, "#revision-chip")

    lv |> element("button[phx-value-panel=history]") |> render_click()
    lv |> element("#start-revision") |> render_click()

    assert_push_event(lv, "revision", %{base: "INT. HALL - DAY #1#\n\nA lamp.", color: "blue"})
    assert has_element?(lv, "#revision-chip", "Blue")
    assert has_element?(lv, "#start-revision", "Start Pink revision")
  end

  test "picks which revision's changes to show, and ends revision mode", ctx do
    %{conn: conn, scope: scope, script: script} = ctx
    {:ok, blue} = Scripts.start_revision(scope, script)
    {:ok, _pink} = Scripts.start_revision(scope, script)

    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}")
    assert has_element?(lv, "#revision-chip", "Pink")

    lv |> element("button[phx-value-panel=history]") |> render_click()
    lv |> element("#revision-section button[phx-value-id='#{blue.id}']") |> render_click()
    assert_push_event(lv, "revision", %{color: "blue"})
    assert has_element?(lv, "#revision-chip", "Blue")

    render_click(lv, "show_revision", %{"id" => "not-an-id"})
    assert has_element?(lv, "#revision-chip", "Pink")

    lv |> element("#clear-revisions") |> render_click()
    refute has_element?(lv, "#revision-chip")
  end
end
