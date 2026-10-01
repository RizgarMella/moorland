defmodule MoorlandWeb.DocumentKindsLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: Scope.for_user(user)}
  end

  defp create(conn, kind) do
    {:ok, lv, _html} = live(conn, ~p"/scripts")

    lv
    |> form("#create-script-form", %{"title" => "New #{kind}", "kind" => kind})
    |> render_submit()

    {path, _} = assert_redirect(lv)
    path
  end

  test "a comic starts from its template and reports its pages", %{conn: conn, scope: scope} do
    path = create(conn, "comic")
    [comic] = Scripts.list_scripts(scope)
    assert comic.kind == "comic" and comic.content =~ "## Panel 1"

    {:ok, lv, _html} = live(conn, path)
    assert has_element?(lv, "#editor-root[data-kind=comic][data-can-lock-pages=false]")
    refute has_element?(lv, "button[phx-value-panel=breakdown]")

    lv |> element("button[phx-value-panel=reports]") |> render_click()
    assert has_element?(lv, "#comic-pages")
  end

  test "a multi-cam keeps breakdowns and sides; a stage play does not", %{conn: conn} do
    {:ok, lv, _html} = live(conn, create(conn, "multicam"))
    assert has_element?(lv, "button[phx-value-panel=breakdown]")
    assert has_element?(lv, "button[phx-value-format=sides]")
    refute has_element?(lv, "#editor-root[data-can-lock-pages=true]")

    {:ok, lv, _html} = live(conn, create(conn, "stageplay"))
    refute has_element?(lv, "button[phx-value-panel=breakdown]")
    refute has_element?(lv, "button[phx-value-format=sides]")
  end

  test "a treatment is prose that starts from the treatment outline", %{conn: conn, scope: scope} do
    create(conn, "treatment")
    [doc] = Scripts.list_scripts(scope)
    assert doc.kind == "prose" and doc.content =~ "# Logline"

    {:ok, lv, _html} = live(conn, ~p"/scripts")
    assert render(lv) =~ "Prose"
  end
end
