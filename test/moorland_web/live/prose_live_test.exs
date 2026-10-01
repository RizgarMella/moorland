defmodule MoorlandWeb.ProseLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Peers
  alias Moorland.Peers.Crypto
  alias Moorland.Scripts
  alias Moorland.Scripts.Stats

  @story """
  # Chapter One

  The *tide* came in.
  It kept coming.

  ***

  ## Morning

  > A line remembered.

  /* cut: a paragraph she deleted */
  # Chapter Two

  Nothing.
  """

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: Scope.for_user(user)}
  end

  test "prose statistics count words, chapters and reading time" do
    stats = Stats.compute_prose(@story)

    # Headings count, marks and breaks and the boneyard do not.
    assert stats.words == 16
    assert stats.chapters == 2
    assert %{pages: 1, minutes: 1, prose: true, characters: [], scene_count: 0} = stats
    assert Stats.compute_prose("").pages == 0
    assert Stats.compute_prose(String.duplicate("word ", 600)).pages == 3
  end

  test "documents are screenplays or prose, nothing else", %{scope: scope} do
    {:ok, s} = Scripts.create_script(scope, %{title: "Default"})
    assert s.kind == "screenplay"
    assert {:error, cs} = Scripts.create_script(scope, %{title: "X", kind: "poem"})
    assert "is invalid" in Moorland.DataCase.errors_on(cs).kind
  end

  test "the dashboard starts a story", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/scripts")

    lv |> form("#create-script-form", %{"title" => "Tide", "kind" => "prose"}) |> render_submit()
    {path, _} = assert_redirect(lv)
    [story] = Scripts.list_scripts(scope)
    assert story.kind == "prose" and path == "/scripts/#{story.id}"

    {:ok, lv, _html} = live(conn, ~p"/scripts")
    assert render(lv) =~ "Prose"
  end

  test "the editor drops screenplay-only tools for prose", %{conn: conn, scope: scope} do
    {:ok, story} = Scripts.create_script(scope, %{title: "Tide", content: @story, kind: "prose"})
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{story.id}")

    assert has_element?(lv, "#editor-root[data-kind=prose]")
    refute has_element?(lv, "#tidy-button")
    refute has_element?(lv, "button[phx-value-panel=breakdown]")
    refute has_element?(lv, "button[phx-value-format=fdx]")
    assert has_element?(lv, "button[phx-value-format=markdown]")

    lv |> element("button[phx-value-panel=reports]") |> render_click()
    assert render(lv) =~ "manuscript pages"
    assert render(lv) =~ "chapters"
    refute render(lv) =~ "est. runtime"
  end

  test "a screenplay keeps its tools", %{conn: conn, scope: scope} do
    {:ok, script} = Scripts.create_script(scope, %{title: "Play"})
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}")
    assert has_element?(lv, "#editor-root[data-kind=screenplay]")
    assert has_element?(lv, "#tidy-button")
    assert has_element?(lv, "button[phx-value-panel=breakdown]")
  end

  test "a peer's mirror of a story is a story", %{scope: scope} do
    {:ok, story} = Scripts.create_script(scope, %{title: "Tide", content: "# One", kind: "prose"})
    keys = Crypto.generate_keypair()
    {:ok, peer} = Peers.add_peer(scope, Crypto.format_code(keys.public, "10.0.0.3", 4000), "Sam")
    :ok = Scripts.set_peer_share(scope, story, peer.id, "editor")

    {:ok, data} = Scripts.peer_fetch(keys.public, story.id)
    data = data |> Jason.encode!() |> Jason.decode!()
    assert data["kind"] == "prose"

    other_keys = Crypto.generate_keypair()
    other = Scope.for_user(user_fixture())

    {:ok, origin} =
      Peers.add_peer(other, Crypto.format_code(other_keys.public, "10.0.0.4", 4000), "Ana")

    {:ok, mirror} = Scripts.create_mirror(origin, data)
    assert mirror.kind == "prose"

    # An origin from before prose sends no kind.
    {:ok, old} = Scripts.create_mirror(origin, %{Map.delete(data, "kind") | "id" => story.id + 1})
    assert old.kind == "screenplay"
  end

  test "Reports for prose adds chapters and style pointers that go to their lines", %{
    conn: conn,
    scope: scope
  } do
    {:ok, story} =
      Scripts.create_script(scope, %{
        title: "Tide",
        kind: "prose",
        content:
          "# One\n\nThe lamp turned slowly. The lamp was broken. The lamp went dark.\n\n# Two\n\nNothing."
      })

    {:ok, lv, _html} = live(conn, ~p"/scripts/#{story.id}")
    lv |> element("button[phx-value-panel=reports]") |> render_click()

    assert has_element?(lv, "#prose-chapters", "One")
    assert has_element?(lv, "#prose-chapters", "Two")
    assert has_element?(lv, "#prose-style", "“lamp” ×3")
    assert has_element?(lv, "#prose-style", "was broken")

    lv |> element("#prose-style button", "slowly") |> render_click()
    assert_push_event(lv, "jump_to_line", %{line: "2"})
  end

  test "screenplays have no prose report", %{conn: conn, scope: scope} do
    {:ok, play} = Scripts.create_script(scope, %{title: "Play"})
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{play.id}")
    lv |> element("button[phx-value-panel=reports]") |> render_click()
    refute has_element?(lv, "#prose-report")
  end
end
