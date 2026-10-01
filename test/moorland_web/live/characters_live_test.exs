defmodule MoorlandWeb.CharactersLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: Scope.for_user(user)}
  end

  defp open_characters(conn, script) do
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}")
    lv |> element("button[phx-value-panel=notes]") |> render_click()
    lv |> element("#notes-tab-character") |> render_click()
    lv
  end

  test "a story's names are listed and get sheets", %{conn: conn, scope: scope} do
    {:ok, story} =
      Scripts.create_script(scope, %{
        title: "Lamp",
        kind: "prose",
        content:
          "When Anna came home on Tuesday, Marchbanks was there. She looked at Anna. Anna smiled."
      })

    lv = open_characters(conn, story)
    assert has_element?(lv, "#character-anna", "3")
    assert has_element?(lv, "#character-marchbanks")
    refute has_element?(lv, "#character-when")
    refute has_element?(lv, "#character-tuesday")

    lv |> element("#character-anna button", "+ Sheet") |> render_click()
    [sheet] = Scripts.list_notes(story)
    assert %{kind: "character"} = sheet
    assert sheet.body =~ "Anna\nRole: \nAge: "

    lv
    |> form("#sheet-form-#{sheet.id}", %{"body" => "Anna\nRole: the keeper's daughter"})
    |> render_submit()

    assert [%{body: "Anna\nRole: the keeper's daughter"}] = Scripts.list_notes(story)

    # Sheets stay off the Notes tab.
    lv |> element("#notes-tab-note") |> render_click()
    refute render(lv) =~ "keeper&#39;s daughter"
  end

  test "a script lists its speaking parts, and sheets for people not written in yet", %{
    conn: conn,
    scope: scope
  } do
    {:ok, script} =
      Scripts.create_script(scope, %{
        title: "Play",
        content: "INT. A - DAY\n\nNORA\nHi.\n\nNORA\nBye."
      })

    lv = open_characters(conn, script)

    assert has_element?(lv, "#character-nora", "2")
    lv |> form("#add-character-form", %{"name" => "The Inspector"}) |> render_submit()
    assert has_element?(lv, "#character-the-inspector", "not in yet")
  end
end
