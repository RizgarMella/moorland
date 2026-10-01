defmodule MoorlandWeb.ProductionLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts
  alias Moorland.Scripts.ProductionTask

  setup %{conn: conn} do
    user = user_fixture()
    scope = Scope.for_user(user)

    {:ok, script} =
      Scripts.create_script(scope, %{title: "Lighthouse", content: "INT. HALL - DAY\n\nA lamp."})

    %{conn: log_in_user(conn, user), scope: scope, script: script}
  end

  defp task(scope, script, attrs) do
    {:ok, task} =
      Scripts.create_task(scope, script, Map.merge(%{title: "Book the lighthouse"}, attrs))

    task
  end

  test "tasks are validated", %{scope: scope, script: script} do
    assert {:error, cs} = Scripts.create_task(scope, script, %{title: " ", phase: "wrap"})
    errors = Moorland.DataCase.errors_on(cs)
    assert "can't be blank" in errors.title and "is invalid" in errors.phase

    assert {:error, cs} =
             Scripts.create_task(scope, script, %{
               title: "Scout",
               starts_on: ~D[2026-10-10],
               due_on: ~D[2026-10-01]
             })

    assert "is before the start" in Moorland.DataCase.errors_on(cs).due_on

    assert {:error, cs} =
             Scripts.create_task(scope, script, %{title: "Scout", starts_on: ~D[2026-10-10]})

    assert "is needed when there is a start date" in Moorland.DataCase.errors_on(cs).due_on

    assert {:ok, %{assignee: nil}} =
             Scripts.create_task(scope, script, %{title: "Scout", assignee: "  "})
  end

  test "overdue and calendar placement" do
    today = ~D[2026-10-15]
    assert ProductionTask.overdue?(%{status: "todo", due_on: ~D[2026-10-14]}, today)
    refute ProductionTask.overdue?(%{status: "done", due_on: ~D[2026-10-14]}, today)
    refute ProductionTask.overdue?(%{status: "todo", due_on: nil}, today)

    span = %{starts_on: ~D[2026-10-01], due_on: ~D[2026-10-05]}
    assert ProductionTask.on_day?(span, ~D[2026-10-03])
    refute ProductionTask.on_day?(span, ~D[2026-10-06])
    assert ProductionTask.on_day?(%{starts_on: nil, due_on: ~D[2026-10-06]}, ~D[2026-10-06])
  end

  test "commenters add and move tasks; only author or editor change them", %{
    scope: scope,
    script: script
  } do
    commenter = user_fixture()
    {:ok, _} = Scripts.add_collaborator(scope, script, commenter.email, "commenter")
    crew = Scope.for_user(commenter)

    mine = task(crew, script, %{title: "Hire a boat"})
    theirs = task(scope, script, %{})

    assert {:ok, %{status: "doing"}} = Scripts.set_task_status(crew, script, theirs.id, "doing")

    assert {:error, :not_allowed} =
             Scripts.update_task(crew, script, theirs.id, %{"title" => "x"})

    assert {:error, :not_allowed} = Scripts.delete_task(crew, script, theirs.id)

    assert {:ok, %{title: "Hire two boats"}} =
             Scripts.update_task(crew, script, mine.id, %{"title" => "Hire two boats"})

    assert {:error, %Ecto.Changeset{}} = Scripts.set_task_status(crew, script, mine.id, "lost")
    assert {:error, :not_found} = Scripts.set_task_status(crew, script, "nope", "done")

    viewer = user_fixture()
    {:ok, _} = Scripts.add_collaborator(scope, script, viewer.email, "viewer")

    assert {:error, :not_allowed} =
             Scripts.create_task(Scope.for_user(viewer), script, %{title: "x"})
  end

  test "the board adds, moves, edits and deletes tasks", %{conn: conn, script: script} do
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/production")

    lv
    |> form("#add-task", %{
      "task" => %{
        "title" => "Cast Anna",
        "phase" => "prep",
        "assignee" => "Sam",
        "due_on" => "2020-01-01"
      }
    })
    |> render_submit()

    [t] = Scripts.list_tasks(script)
    assert has_element?(lv, "#column-todo #task-#{t.id}", "Cast Anna")
    # The form comes back empty, ready for the next task.
    assert has_element?(lv, "#add-task-fields-1 input[name='task[title]']:not([value])")
    assert has_element?(lv, "#task-#{t.id} .text-error", "1 Jan")

    lv |> element("#task-#{t.id} button[phx-value-status=doing]") |> render_click()
    assert has_element?(lv, "#column-doing #task-#{t.id}")

    lv |> element("#task-#{t.id} button[title=Edit]") |> render_click()

    lv
    |> form("#edit-task-#{t.id}", %{"task" => %{"title" => "Cast Anna and Tom"}})
    |> render_submit()

    assert has_element?(lv, "#task-#{t.id}", "Cast Anna and Tom")

    lv |> element("#task-#{t.id} button[title=Delete]") |> render_click()
    refute has_element?(lv, "#task-#{t.id}")
  end

  test "the calendar shows spans, due dates and shoot days", %{
    conn: conn,
    scope: scope,
    script: script
  } do
    task(scope, script, %{title: "Prep", starts_on: ~D[2026-10-05], due_on: ~D[2026-10-09]})
    task(scope, script, %{title: "Lock the script", due_on: ~D[2026-10-12]})
    {:ok, _} = Scripts.schedule_scene(scope, script, %{heading: "INT. HALL - DAY", line_no: 0})
    {:ok, day} = Scripts.add_day_break(scope, script)
    {:ok, _} = Scripts.update_day_break(scope, script, day.id, %{"shoot_date" => "2026-10-14"})

    {:ok, lv, _html} =
      live(conn, ~p"/scripts/#{script.id}/production?view=calendar&month=2026-10")

    assert has_element?(lv, "#calendar h2", "October 2026")
    assert has_element?(lv, "#day-2026-10-07", "Prep")
    refute has_element?(lv, "#day-2026-10-10", "Prep")
    assert has_element?(lv, "#day-2026-10-12", "Lock the script")
    assert has_element?(lv, "#day-2026-10-14", "Shoot 1")

    lv |> element("#next-month") |> render_click()
    assert has_element?(lv, "#calendar h2", "November 2026")
  end

  test "viewers see the board read-only", %{scope: scope, script: script} do
    task(scope, script, %{})
    viewer = user_fixture()
    {:ok, _} = Scripts.add_collaborator(scope, script, viewer.email, "viewer")

    {:ok, lv, _html} =
      build_conn() |> log_in_user(viewer) |> live(~p"/scripts/#{script.id}/production")

    assert has_element?(lv, "#column-todo", "Book the lighthouse")
    refute has_element?(lv, "#add-task")
    refute has_element?(lv, "button[phx-click=move]")
  end
end
