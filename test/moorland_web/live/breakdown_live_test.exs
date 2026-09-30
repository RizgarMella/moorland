defmodule MoorlandWeb.BreakdownLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts

  @content """
  INT. GARAGE - NIGHT

  A red bicycle leans on the wall.

  NORA
  Whose is this?

  EXT. ROAD - DAY

  The bicycle speeds past a police car.
  """

  setup %{conn: conn} do
    user = user_fixture()
    scope = Scope.for_user(user)
    {:ok, script} = Scripts.create_script(scope, %{title: "Ride"})
    {:ok, script} = Scripts.save_content(scope, script, @content)
    %{conn: log_in_user(conn, user), user: user, scope: scope, script: script}
  end

  defp tag(scope, script, category, name, anchor, line) do
    {:ok, tag} =
      Scripts.create_breakdown_tag(scope, script, %{
        category: category,
        name: name,
        anchor_text: anchor,
        line_no: line
      })

    tag
  end

  describe "breakdown page" do
    test "shows a sheet per scene with speaking cast seeded", %{conn: conn, script: script} do
      {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/breakdown")

      assert has_element?(lv, "#scene-1", "INT. GARAGE - NIGHT")
      assert has_element?(lv, "#scene-2", "EXT. ROAD - DAY")
      assert has_element?(lv, "#scene-1 .bd-cat-cast", "NORA")
      refute has_element?(lv, "#scene-2 .bd-cat-cast")
    end

    test "places tags in their scenes", %{conn: conn, scope: scope, script: script} do
      tag(scope, script, "props", "Bicycle", "red bicycle", 2)
      tag(scope, script, "vehicles", "Police car", "police car", 9)

      {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/breakdown")

      assert has_element?(lv, "#scene-1 .bd-cat-props", "Bicycle")
      assert has_element?(lv, "#scene-2 .bd-cat-vehicles", "Police car")
      refute has_element?(lv, "#scene-1 .bd-cat-vehicles")
    end

    test "adds an element to a scene and removes it", %{conn: conn, script: script} do
      {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/breakdown")

      lv
      |> form("#add-element-2", %{"category" => "sfx", "name" => "Rain"})
      |> render_submit()

      assert has_element?(lv, "#scene-2 .bd-cat-sfx", "Rain")

      lv |> element("#scene-2 .bd-cat-sfx button[phx-click=remove_tags]") |> render_click()
      refute has_element?(lv, "#scene-2 .bd-cat-sfx")
    end

    test "a scene element stays with its scene when scenes above it grow", ctx do
      %{conn: conn, scope: scope, script: script} = ctx
      {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/breakdown")

      lv
      |> form("#add-element-2", %{"category" => "sfx", "name" => "Rain"})
      |> render_submit()

      longer = String.replace(@content, "Whose is this?", "Whose is this?\n\nNobody answers.")
      {:ok, _} = Scripts.save_content(scope, script, longer, script.content_version)

      assert has_element?(lv, "#scene-2 .bd-cat-sfx", "Rain")
    end

    test "department view lists elements with their scenes", ctx do
      %{conn: conn, scope: scope, script: script} = ctx
      tag(scope, script, "props", "Bicycle", "red bicycle", 2)
      tag(scope, script, "props", "bicycle", "bicycle", 9)

      {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/breakdown?tab=departments")

      assert has_element?(lv, "#dept-props", "Bicycle")
      assert has_element?(lv, "#dept-props a", "1")
      assert has_element?(lv, "#dept-props a", "2")
      assert has_element?(lv, "#dept-cast", "NORA")
    end

    test "renames an element across scenes", ctx do
      %{conn: conn, scope: scope, script: script} = ctx
      tag(scope, script, "props", "Bicycle", "red bicycle", 2)
      tag(scope, script, "props", "bicycle", "bicycle", 9)

      {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/breakdown?tab=departments")
      lv |> element("#dept-props button[phx-click=edit_element]") |> render_click()

      lv
      |> form("#edit-element-props-bicycle", %{
        "name" => "Racing bike",
        "new_category" => "vehicles"
      })
      |> render_submit()

      assert has_element?(lv, "#dept-vehicles", "Racing bike")
      refute has_element?(lv, "#dept-props li")
    end

    test "lists tags whose words were cut", ctx do
      %{conn: conn, scope: scope, script: script} = ctx
      tag(scope, script, "vehicles", "Police car", "police car", 9)
      cut = String.replace(@content, " past a police car", "")
      {:ok, _} = Scripts.save_content(scope, script, cut, script.content_version)

      {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/breakdown")
      assert has_element?(lv, "#unplaced-tags", "Police car")
    end

    test "viewers see the breakdown but cannot change it", %{script: script, scope: scope} do
      viewer = user_fixture()
      {:ok, _} = Scripts.add_collaborator(scope, script, viewer.email, "viewer")
      tag(scope, script, "props", "Bicycle", "red bicycle", 2)

      {:ok, lv, _html} =
        build_conn() |> log_in_user(viewer) |> live(~p"/scripts/#{script.id}/breakdown")

      assert has_element?(lv, "#scene-1 .bd-cat-props", "Bicycle")
      refute has_element?(lv, "#add-element-1")
      refute has_element?(lv, "button[phx-click=remove_tags]")
    end

    test "strangers cannot open it", %{script: script} do
      stranger = build_conn() |> log_in_user(user_fixture())

      assert_raise Ecto.NoResultsError, fn ->
        live(stranger, ~p"/scripts/#{script.id}/breakdown")
      end
    end
  end

  describe "editor breakdown panel" do
    test "tags a preview selection", %{conn: conn, script: script} do
      {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}")

      render_hook(lv, "tag_selection", %{"line" => 2, "text" => "red bicycle"})
      assert has_element?(lv, "#tag-form")
      assert has_element?(lv, "#tag-name[value='red bicycle']")

      lv
      |> form("#tag-form", %{"category" => "props", "name" => "Bicycle"})
      |> render_submit()

      refute has_element?(lv, "#tag-form")
      assert has_element?(lv, "#breakdown-scene .bd-cat-props", "Bicycle")

      assert [%{name: "Bicycle", anchor_text: "red bicycle", line_no: 2}] =
               Scripts.list_breakdown_tags(script)
    end

    test "shows the scene the cursor is in", %{conn: conn, script: script} do
      {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}")
      lv |> element("button[phx-value-panel=breakdown]") |> render_click()

      render_hook(lv, "cursor_line", %{"line" => 9, "text" => "The bicycle speeds past"})
      assert has_element?(lv, "#breakdown-scene", "EXT. ROAD - DAY")

      render_hook(lv, "cursor_line", %{"line" => 4, "text" => "NORA"})
      assert has_element?(lv, "#breakdown-scene", "INT. GARAGE - NIGHT")
      assert has_element?(lv, "#breakdown-scene .bd-cat-cast", "NORA")
    end

    test "updates live when someone else tags", %{conn: conn, scope: scope, script: script} do
      {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}")
      lv |> element("button[phx-value-panel=breakdown]") |> render_click()
      render_hook(lv, "cursor_line", %{"line" => 2, "text" => ""})

      tag(scope, script, "props", "Bicycle", "red bicycle", 2)
      assert has_element?(lv, "#breakdown-scene .bd-cat-props", "Bicycle")

      assert_push_event(lv, "breakdown_tags", %{tags: [%{text: "red bicycle", category: "props"}]})
    end
  end

  describe "CSV download" do
    test "downloads the breakdown for members", %{conn: conn, scope: scope, script: script} do
      tag(scope, script, "props", "Bicycle", "red bicycle", 2)
      conn = get(conn, ~p"/scripts/#{script.id}/breakdown.csv")

      assert response_content_type(conn, :csv) =~ "text/csv"
      assert get_resp_header(conn, "content-disposition") |> hd() =~ "Ride%20-%20breakdown.csv"
      assert response(conn, 200) =~ "1,INT. GARAGE - NIGHT,INT,NIGHT,2,Props,Bicycle"
    end

    test "is not found for strangers", %{script: script} do
      conn = build_conn() |> log_in_user(user_fixture())

      assert_error_sent 404, fn -> get(conn, ~p"/scripts/#{script.id}/breakdown.csv") end
    end
  end
end
