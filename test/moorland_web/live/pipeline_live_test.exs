defmodule MoorlandWeb.PipelineLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: Scope.for_user(user), user: user}
  end

  defp idea(scope, content \\ "A keeper sees the lamp go out.") do
    {:ok, idea} =
      Scripts.create_script(scope, %{
        title: "Lamp",
        kind: "prose",
        stage: "idea",
        content: content
      })

    idea
  end

  test "a stage must fit its kind", %{scope: scope} do
    assert {:error, cs} =
             Scripts.create_script(scope, %{title: "X", kind: "screenplay", stage: "idea"})

    assert "doesn't fit a screenplay" in Moorland.DataCase.errors_on(cs).stage

    assert {:error, cs} =
             Scripts.create_script(scope, %{title: "X", kind: "prose", stage: "draft"})

    assert "is invalid" in Moorland.DataCase.errors_on(cs).stage
  end

  test "each stage starts the next, ending in an adapted script", %{scope: scope} do
    idea = idea(scope)
    {:ok, short} = Scripts.start_next_stage(scope, idea)

    assert %{stage: "short_story", kind: "prose", content: "A keeper sees the lamp go out."} =
             short

    assert short.parent_script_id == idea.id

    {:ok, story} = Scripts.save_content(scope, short, "## Night\n\nThe lamp went out.")
    {:ok, story} = Scripts.start_next_stage(scope, story)
    {:ok, story} = Scripts.save_content(scope, story, "## Night\n\nThe lamp went out.")
    {:ok, script} = Scripts.start_next_stage(scope, story)

    assert %{stage: "script", kind: "screenplay"} = script
    assert script.content =~ ".NIGHT\n\n= The lamp went out."
    assert {:error, :last_stage} = Scripts.start_next_stage(scope, script)

    assert scope |> Scripts.lineage(short) |> Enum.map(& &1.stage) ==
             ~w(idea short_story story script)
  end

  test "documents outside a pipeline have no next stage", %{scope: scope} do
    {:ok, plain} = Scripts.create_script(scope, %{title: "Plain"})
    assert {:error, :last_stage} = Scripts.start_next_stage(scope, plain)
  end

  test "lineage shows only what the caller may open", %{scope: scope} do
    idea = idea(scope)
    other = Scope.for_user(user_fixture())
    {:ok, _} = Scripts.add_collaborator(scope, idea, other.user.email, "viewer")

    # A collaborator can grow the idea into their own short story...
    {:ok, theirs} = Scripts.start_next_stage(other, idea)
    assert theirs.owner_id == other.user.id
    # ...which the idea's owner cannot see unless shared.
    assert scope |> Scripts.lineage(idea) |> Enum.map(& &1.id) == [idea.id]
    assert other |> Scripts.lineage(theirs) |> Enum.map(& &1.id) == [idea.id, theirs.id]
  end

  test "the editor shows the stages and starts the next one", %{conn: conn, scope: scope} do
    idea = idea(scope)
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{idea.id}")

    assert has_element?(lv, "#stages-strip a[aria-current=page]", "Idea")
    assert has_element?(lv, "#start-next-stage", "Start the short story")

    lv |> element("#start-next-stage") |> render_click()
    {path, _} = assert_redirect(lv)
    {:ok, lv, _html} = live(conn, path)
    assert has_element?(lv, "#stages-strip a[aria-current=page]", "Short story")
    assert has_element?(lv, ~s|#stages-strip a[href="/scripts/#{idea.id}"]|, "Idea")
  end

  test "documents outside a pipeline have no strip", %{conn: conn, scope: scope} do
    {:ok, plain} = Scripts.create_script(scope, %{title: "Plain"})
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{plain.id}")
    refute has_element?(lv, "#stages-strip")
  end

  test "the dashboard starts a pipeline at any stage", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/scripts")

    lv
    |> form("#create-script-form", %{"title" => "Lamp", "kind" => "stage:story"})
    |> render_submit()

    assert [%{stage: "story", kind: "prose"}] = Scripts.list_scripts(scope)
  end
end
