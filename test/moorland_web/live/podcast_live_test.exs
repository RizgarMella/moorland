defmodule MoorlandWeb.PodcastLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: Scope.for_user(user)}
  end

  test "a new episode starts from the template", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/scripts")

    lv
    |> form("#create-script-form", %{"title" => "Episode 1", "kind" => "podcast"})
    |> render_submit()

    assert [%{kind: "podcast", content: content}] = Scripts.list_scripts(scope)
    assert content =~ "# Cold open" and content =~ "HOST"

    {:ok, lv, _html} = live(conn, ~p"/scripts")
    assert render(lv) =~ "Podcast"
  end

  test "the editor times segments and drops shoot tools", %{conn: conn, scope: scope} do
    {:ok, ep} =
      Scripts.create_script(scope, %{
        title: "Ep",
        kind: "podcast",
        content: Moorland.Scripts.Script.template("podcast")
      })

    {:ok, lv, _html} = live(conn, ~p"/scripts/#{ep.id}")
    assert has_element?(lv, "#editor-root[data-kind=podcast]")
    refute has_element?(lv, "button[phx-value-panel=breakdown]")
    refute has_element?(lv, "button[phx-value-format=sides]")
    assert has_element?(lv, "button[phx-value-format=fdx]")

    lv |> element("button[phx-value-panel=reports]") |> render_click()
    assert has_element?(lv, "#podcast-segments", "Ad break")
    assert has_element?(lv, "#podcast-segments tfoot", "Total")
    assert render(lv) =~ "speakers"
    assert render(lv) =~ "Speakers"
  end
end
