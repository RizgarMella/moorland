defmodule MoorlandWeb.SketchLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts
  alias Moorland.Scripts.Stats

  setup %{conn: conn} do
    user = user_fixture()
    scope = Scope.for_user(user)
    {:ok, script} = Scripts.create_script(scope, %{title: "Draft"})
    %{conn: log_in_user(conn, user), scope: scope, script: script}
  end

  test "a sketch starts a new script with the sketch in its boneyard", %{
    scope: scope,
    script: script
  } do
    {:ok, sketch} =
      Scripts.create_note(scope, script, %{
        body: "  A lighthouse keeper who can't sleep\nShe hears */ the sea talking.",
        kind: "sketch"
      })

    assert {:ok, new} = Scripts.start_script_from_sketch(scope, script, to_string(sketch.id))
    assert new.title == "A lighthouse keeper who can't sleep"
    assert new.content =~ "She hears * / the sea talking."
    assert String.starts_with?(new.content, "/*\nFrom a sketch:")
    # The boneyard holds it all: nothing of it counts as script.
    assert Stats.compute(new.content).words == 0
    assert {_s, :owner} = Scripts.get_script!(scope, new.id)
  end

  test "only sketches start scripts", %{scope: scope, script: script} do
    {:ok, note} = Scripts.create_note(scope, script, %{body: "Buy milk"})
    assert {:error, :not_found} = Scripts.start_script_from_sketch(scope, script, note.id)
    assert {:error, :not_found} = Scripts.start_script_from_sketch(scope, script, "x")
  end

  test "note kinds are validated", %{scope: scope, script: script} do
    assert {:error, cs} = Scripts.create_note(scope, script, %{body: "x", kind: "poem"})
    assert "is invalid" in Moorland.DataCase.errors_on(cs).kind
  end

  test "the notes panel keeps sketches on their own tab", %{conn: conn, script: script} do
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}")
    lv |> element("button[phx-value-panel=notes]") |> render_click()

    lv
    |> form("#add-note-form", %{"body" => "Check the tide tables", "color" => "yellow"})
    |> render_submit()

    lv |> element("#notes-tab-sketch") |> render_click()
    refute render(lv) =~ "Check the tide tables"

    lv
    |> form("#add-note-form", %{
      "body" => "The keeper's daughter\nReturns after ten years.",
      "color" => "blue"
    })
    |> render_submit()

    assert render(lv) =~ "The keeper&#39;s daughter"
    assert has_element?(lv, "#notes-tab-sketch", "1")

    lv |> element("button[phx-click=script_from_sketch]") |> render_click()
    {path, _flash} = assert_redirect(lv)
    assert path =~ ~r{^/scripts/\d+$}
  end
end
