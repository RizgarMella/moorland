defmodule MoorlandWeb.ScriptLive.Production do
  @moduledoc """
  The production office: a task board (to do, doing, done) for prep, shoot
  and post, and a month calendar showing task spans, due dates and the
  shoot days set on the stripboard. Anyone who may comment can add tasks
  and move them along; their author or an editor can change or remove them.
  """
  use MoorlandWeb, :live_view

  alias Moorland.Contacts
  alias Moorland.Scripts
  alias Moorland.Scripts.{ProductionTask, Schedule}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    {script, role} = Scripts.get_script!(scope, id)
    if connected?(socket), do: Scripts.subscribe(script.id)

    {:ok,
     socket
     |> assign(
       script: script,
       role: role,
       page_title: "Production · #{script.title}",
       editing: nil,
       added: 0,
       people: people(scope, script)
     )
     |> reload()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = if params["view"] == "calendar", do: "calendar", else: "board"
    {:noreply, assign(socket, view: view, month: parse_month(params["month"]))}
  end

  defp parse_month(text) when is_binary(text) do
    case Date.from_iso8601(text <> "-01") do
      {:ok, date} -> date
      _ -> Date.beginning_of_month(Date.utc_today())
    end
  end

  defp parse_month(_), do: Date.beginning_of_month(Date.utc_today())

  defp reload(socket) do
    %{script: script} = socket.assigns

    board =
      Schedule.build(
        script.content,
        Scripts.list_breakdown_tags(script),
        Scripts.list_schedule_items(script)
      )

    assign(socket,
      tasks: Scripts.list_tasks(script),
      shoot_days: for(day <- board.shoot_days, day.date, do: {day.date, day.day}) |> Map.new()
    )
  end

  # Names to assign to: the script's people and the viewer's contacts.
  defp people(scope, script) do
    script = Moorland.Repo.preload(script, :owner)
    members = [script.owner | Enum.map(Scripts.list_collaborators(script), & &1.user)]

    (Enum.map(members, &(&1.email |> String.split("@") |> hd())) ++
       Enum.map(Contacts.list_contacts(scope), & &1.name))
    |> Enum.uniq()
    |> Enum.sort()
  end

  ## Events

  @impl true
  def handle_event("add_task", %{"task" => attrs}, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    case Scripts.create_task(scope, script, blanks_to_nil(attrs)) do
      # A fresh set of fields clears the form for the next task.
      {:ok, _} -> {:noreply, socket |> update(:added, &(&1 + 1)) |> reload()}
      other -> respond(other, socket)
    end
  end

  def handle_event("move", %{"id" => id, "status" => status}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.set_task_status(scope, script, id, status) |> respond(socket)
  end

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, :editing, String.to_integer(id))}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :editing, nil)}

  def handle_event("save_task", %{"task_id" => id, "task" => attrs}, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    case Scripts.update_task(scope, script, id, blanks_to_nil(attrs)) do
      {:ok, _} -> {:noreply, socket |> assign(:editing, nil) |> reload()}
      other -> respond(other, socket)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.delete_task(scope, script, id) |> respond(socket)
  end

  defp blanks_to_nil(attrs),
    do: Map.new(attrs, fn {k, v} -> {k, if(v == "", do: nil, else: v)} end)

  defp respond({:error, :not_allowed}, socket),
    do: {:noreply, put_flash(socket, :error, "That task is someone else's to change.")}

  defp respond({:error, %Ecto.Changeset{} = cs}, socket),
    do: {:noreply, put_flash(socket, :error, error_text(cs))}

  defp respond({:error, _}, socket), do: {:noreply, reload(socket)}
  defp respond(_ok, socket), do: {:noreply, reload(socket)}

  defp error_text(cs) do
    cs.errors
    |> Enum.map(fn {field, {msg, _}} -> "#{Phoenix.Naming.humanize(field)} #{msg}" end)
    |> Enum.join("; ")
  end

  @impl true
  def handle_info({event, _id}, socket)
      when event in [:tasks_changed, :schedule_changed, :breakdown_changed],
      do: {:noreply, reload(socket)}

  def handle_info({:content_saved, _id, _user_id, content, version}, socket) do
    {:noreply,
     socket
     |> update(:script, &%{&1 | content: content, content_version: version})
     |> reload()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Helpers

  defp can_change?(task, role, user_id),
    do: task.author_id == user_id or Scripts.can_edit?(role)

  defp phase_class("prep"), do: "bg-amber-500/15 text-amber-700 dark:text-amber-300"
  defp phase_class("shoot"), do: "bg-sky-500/15 text-sky-700 dark:text-sky-300"
  defp phase_class(_post), do: "bg-violet-500/15 text-violet-700 dark:text-violet-300"

  defp short_date(nil), do: nil
  defp short_date(%Date{} = d), do: Calendar.strftime(d, "%-d %b")

  defp neighbours(status) do
    keys = ProductionTask.status_keys()
    i = Enum.find_index(keys, &(&1 == status))
    {if(i > 0, do: Enum.at(keys, i - 1)), Enum.at(keys, i + 1)}
  end

  # Six Monday-first weeks covering the month.
  defp weeks(month) do
    first = Date.beginning_of_week(month, :monday)
    first |> Date.range(Date.add(first, 41)) |> Enum.chunk_every(7)
  end

  ## Render

  @impl true
  def render(assigns) do
    assigns = assign(assigns, today: Date.utc_today())

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} section={:scripts} wide>
      <div class="py-2">
        <MoorlandWeb.ProductionComponents.production_header
          script={@script}
          current={:production}
          title="Production"
        >
        </MoorlandWeb.ProductionComponents.production_header>

        <div class="mt-6 inline-flex items-center gap-0.5 rounded-lg bg-base-200 p-0.5">
          <.link
            :for={
              {view, label, icon} <- [
                {"board", "Tasks", "hero-view-columns"},
                {"calendar", "Calendar", "hero-calendar"}
              ]
            }
            id={"view-#{view}"}
            patch={~p"/scripts/#{@script.id}/production?view=#{view}"}
            class={[
              "flex items-center gap-1.5 rounded-md px-3 py-1 text-xs font-medium transition",
              @view == view && "bg-base-100 shadow-sm",
              @view != view && "text-base-content/60 hover:text-base-content"
            ]}
          >
            <.icon name={icon} class="size-4" />
            {label}
          </.link>
        </div>

        <.add_form :if={Scripts.can_comment?(@role)} people={@people} added={@added} />

        <div :if={@view == "board"} id="task-board" class="mt-6 grid gap-4 md:grid-cols-3">
          <section
            :for={{status, label} <- ProductionTask.statuses()}
            id={"column-#{status}"}
            class="rounded-lg bg-base-200/50 p-3"
          >
            <h2 class="flex items-center justify-between text-xs font-semibold uppercase tracking-wider text-base-content/60">
              {label}
              <span class="tabular-nums">{Enum.count(@tasks, &(&1.status == status))}</span>
            </h2>
            <div class="mt-2 space-y-2">
              <.card
                :for={task <- Enum.filter(@tasks, &(&1.status == status))}
                task={task}
                today={@today}
                editing={@editing == task.id}
                can_move={Scripts.can_comment?(@role)}
                can_change={can_change?(task, @role, @current_scope.user.id)}
                people={@people}
              />
              <p
                :if={!Enum.any?(@tasks, &(&1.status == status))}
                class="py-4 text-center text-xs text-base-content/40"
              >
                Nothing here.
              </p>
            </div>
          </section>
        </div>

        <.month
          :if={@view == "calendar"}
          month={@month}
          tasks={@tasks}
          shoot_days={@shoot_days}
          today={@today}
          script={@script}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :people, :list, required: true
  attr :added, :integer, required: true

  defp add_form(assigns) do
    ~H"""
    <form
      id="add-task"
      phx-submit="add_task"
      class="mt-4 rounded-lg border border-base-300 p-3"
    >
      <div
        id={"add-task-fields-#{@added}"}
        class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_7rem_9rem_11rem_11rem_auto]"
      >
        <input
          type="text"
          name="task[title]"
          required
          maxlength="200"
          autocomplete="off"
          placeholder="Add a task: book the lighthouse, cast Anna…"
          aria-label="Task"
          class="input input-bordered input-sm w-full"
        />
        <select name="task[phase]" class="select select-bordered select-sm w-full" aria-label="Phase">
          <option :for={{key, label} <- ProductionTask.phases()} value={key}>{label}</option>
        </select>
        <input
          type="text"
          name="task[assignee]"
          list="people"
          maxlength="80"
          autocomplete="off"
          placeholder="Who"
          aria-label="Assigned to"
          class="input input-bordered input-sm w-full"
        />
        <label class="flex items-center gap-1.5 text-[11px] text-base-content/50">
          <span class="w-8 shrink-0">From</span>
          <input
            type="date"
            name="task[starts_on]"
            class="input input-bordered input-sm min-w-0 flex-1"
          />
        </label>
        <label class="flex items-center gap-1.5 text-[11px] text-base-content/50">
          <span class="w-8 shrink-0">Due</span>
          <input type="date" name="task[due_on]" class="input input-bordered input-sm min-w-0 flex-1" />
        </label>
        <button type="submit" class="btn btn-neutral btn-sm">
          <.icon name="hero-plus" class="size-4" /> Add
        </button>
      </div>
      <datalist id="people">
        <option :for={person <- @people} value={person}></option>
      </datalist>
    </form>
    """
  end

  attr :task, :map, required: true
  attr :today, :any, required: true
  attr :editing, :boolean, required: true
  attr :can_move, :boolean, required: true
  attr :can_change, :boolean, required: true
  attr :people, :list, required: true

  defp card(assigns) do
    assigns = assign(assigns, :around, neighbours(assigns.task.status))

    ~H"""
    <div
      id={"task-#{@task.id}"}
      class="group rounded-md border border-base-300 bg-base-100 p-2.5 shadow-sm"
    >
      <form
        :if={@editing}
        id={"edit-task-#{@task.id}"}
        phx-submit="save_task"
        class="space-y-1.5"
      >
        <input type="hidden" name="task_id" value={@task.id} />
        <input
          type="text"
          name="task[title]"
          value={@task.title}
          required
          class="input input-bordered input-xs w-full"
        />
        <div class="flex gap-1.5">
          <select name="task[phase]" class="select select-bordered select-xs flex-1">
            <option
              :for={{key, label} <- ProductionTask.phases()}
              value={key}
              selected={key == @task.phase}
            >
              {label}
            </option>
          </select>
          <input
            type="text"
            name="task[assignee]"
            value={@task.assignee}
            list="people"
            placeholder="Who"
            class="input input-bordered input-xs flex-1"
          />
        </div>
        <div class="flex gap-1.5">
          <input
            type="date"
            name="task[starts_on]"
            value={@task.starts_on}
            aria-label="From"
            class="input input-bordered input-xs flex-1"
          />
          <input
            type="date"
            name="task[due_on]"
            value={@task.due_on}
            aria-label="Due"
            class="input input-bordered input-xs flex-1"
          />
        </div>
        <div class="flex gap-1.5">
          <button type="submit" class="btn btn-neutral btn-xs">Save</button>
          <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-xs">Cancel</button>
        </div>
      </form>

      <div :if={!@editing}>
        <div class="flex items-start gap-2">
          <span class={[
            "mt-0.5 shrink-0 rounded px-1.5 text-[10px] font-semibold uppercase",
            phase_class(@task.phase)
          ]}>
            {ProductionTask.label(@task.phase)}
          </span>
          <span class={[
            "min-w-0 flex-1 text-sm",
            @task.status == "done" && "text-base-content/50 line-through"
          ]}>
            {@task.title}
          </span>
        </div>
        <div class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-base-content/60">
          <span :if={@task.assignee} class="flex items-center gap-1">
            <.icon name="hero-user" class="size-3" />{@task.assignee}
          </span>
          <span
            :if={@task.due_on}
            class={[
              "flex items-center gap-1",
              ProductionTask.overdue?(@task, @today) && "font-medium text-error"
            ]}
            title={if ProductionTask.overdue?(@task, @today), do: "Overdue"}
          >
            <.icon name="hero-calendar" class="size-3" />
            <span :if={@task.starts_on}>{short_date(@task.starts_on)} –</span>
            {short_date(@task.due_on)}
          </span>
          <span :if={@task.remote_author} title="Added on a peer installation">via {@task.remote_author}</span>
        </div>
        <div class="mt-2 flex items-center gap-1 transition sm:opacity-0 sm:group-hover:opacity-100 focus-within:opacity-100">
          <button
            :if={@can_move && elem(@around, 0)}
            type="button"
            phx-click="move"
            phx-value-id={@task.id}
            phx-value-status={elem(@around, 0)}
            class="rounded p-0.5 text-base-content/50 hover:bg-base-200 hover:text-base-content"
            title={"Back to #{ProductionTask.label(elem(@around, 0))}"}
          >
            <.icon name="hero-arrow-left" class="size-3.5" />
          </button>
          <button
            :if={@can_move && elem(@around, 1)}
            type="button"
            phx-click="move"
            phx-value-id={@task.id}
            phx-value-status={elem(@around, 1)}
            class="rounded p-0.5 text-base-content/50 hover:bg-base-200 hover:text-base-content"
            title={"On to #{ProductionTask.label(elem(@around, 1))}"}
          >
            <.icon name="hero-arrow-right" class="size-3.5" />
          </button>
          <span class="flex-1"></span>
          <button
            :if={@can_change}
            type="button"
            phx-click="edit"
            phx-value-id={@task.id}
            class="rounded p-0.5 text-base-content/40 hover:text-base-content"
            title="Edit"
          >
            <.icon name="hero-pencil" class="size-3.5" />
          </button>
          <button
            :if={@can_change}
            type="button"
            phx-click="delete"
            phx-value-id={@task.id}
            data-confirm="Delete this task?"
            class="rounded p-0.5 text-base-content/40 hover:text-error"
            title="Delete"
          >
            <.icon name="hero-trash" class="size-3.5" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :month, :any, required: true
  attr :tasks, :list, required: true
  attr :shoot_days, :map, required: true
  attr :today, :any, required: true
  attr :script, :map, required: true

  defp month(assigns) do
    prev = assigns.month |> Date.add(-1) |> Date.beginning_of_month()
    next = assigns.month |> Date.end_of_month() |> Date.add(1)

    assigns =
      assign(assigns,
        prev: Calendar.strftime(prev, "%Y-%m"),
        next: Calendar.strftime(next, "%Y-%m")
      )

    ~H"""
    <section id="calendar" class="mt-6">
      <div class="flex items-center gap-2">
        <.link
          id="prev-month"
          patch={~p"/scripts/#{@script.id}/production?view=calendar&month=#{@prev}"}
          class="btn btn-ghost btn-xs"
          title="Previous month"
        >
          <.icon name="hero-chevron-left" class="size-4" />
        </.link>
        <h2 class="min-w-36 text-center text-sm font-semibold">
          {Calendar.strftime(@month, "%B %Y")}
        </h2>
        <.link
          id="next-month"
          patch={~p"/scripts/#{@script.id}/production?view=calendar&month=#{@next}"}
          class="btn btn-ghost btn-xs"
          title="Next month"
        >
          <.icon name="hero-chevron-right" class="size-4" />
        </.link>
      </div>

      <div class="mt-3 overflow-x-auto">
        <div class="grid min-w-[42rem] grid-cols-7 overflow-hidden rounded-lg border border-base-300 text-xs">
          <div
            :for={day <- ~w(Mon Tue Wed Thu Fri Sat Sun)}
            class="border-b border-base-300 bg-base-200/60 px-2 py-1 font-medium text-base-content/60"
          >
            {day}
          </div>
          <%= for week <- weeks(@month), day <- week do %>
            <div
              id={"day-#{Date.to_iso8601(day)}"}
              class={[
                "min-h-24 border-b border-r border-base-200 p-1.5",
                day.month != @month.month && "bg-base-200/30 text-base-content/40"
              ]}
            >
              <div class="flex items-center justify-between">
                <span class={[
                  "flex size-5 items-center justify-center rounded-full tabular-nums",
                  day == @today && "bg-neutral text-neutral-content"
                ]}>
                  {day.day}
                </span>
                <span
                  :if={@shoot_days[day]}
                  class="rounded bg-sky-500/15 px-1 text-[10px] font-semibold text-sky-700 dark:text-sky-300"
                  title="Shoot day on the stripboard"
                >
                  Shoot {@shoot_days[day]}
                </span>
              </div>
              <% todays = Enum.filter(@tasks, &ProductionTask.on_day?(&1, day)) %>
              <div class="mt-1 space-y-0.5">
                <div
                  :for={task <- Enum.take(todays, 3)}
                  class={[
                    "truncate rounded px-1 py-px text-[10px]",
                    phase_class(task.phase),
                    task.status == "done" && "line-through opacity-60"
                  ]}
                  title={task.title}
                >
                  {task.title}
                </div>
                <div :if={length(todays) > 3} class="px-1 text-[10px] text-base-content/50">
                  +{length(todays) - 3} more
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </section>
    """
  end
end
