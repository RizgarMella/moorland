defmodule MoorlandWeb.ScriptLive.Schedule do
  @moduledoc """
  The stripboard: every scene as a coloured strip (INT/EXT by day or night),
  laid out into shoot days separated by end-of-day breaks, with each day's
  page count. Scenes not yet on the board wait in the Unscheduled column.
  Editors drag strips (or use the arrows) to build the shoot; everyone else
  reads it.
  """
  use MoorlandWeb, :live_view

  import MoorlandWeb.BreakdownComponents, only: [eighths: 1, int_ext_label: 1, scene_label: 1]

  alias Moorland.Scripts
  alias Moorland.Scripts.Schedule

  @night_times ~w(NIGHT EVENING DUSK SUNSET MIDNIGHT)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {script, role} = Scripts.get_script!(socket.assigns.current_scope, id)
    if connected?(socket), do: Scripts.subscribe(script.id)

    {:ok,
     socket
     |> assign(
       script: script,
       role: role,
       page_title: "Stripboard · #{script.title}",
       tags: Scripts.list_breakdown_tags(script),
       items: Scripts.list_schedule_items(script)
     )
     |> rebuild()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = if params["view"] == "dood", do: "dood", else: "board"
    {:noreply, assign(socket, :view, view)}
  end

  defp rebuild(socket) do
    %{script: script, tags: tags, items: items} = socket.assigns
    board = Schedule.build(script.content, tags, items)
    socket = assign(socket, :confirmations, Scripts.call_confirmations(script))
    assign(socket, board: board, dood: Schedule.day_out_of_days(board))
  end

  defp reload_items(socket) do
    socket
    |> assign(:items, Scripts.list_schedule_items(socket.assigns.script))
    |> rebuild()
  end

  ## Events

  @impl true
  def handle_event("schedule_scene", %{"heading" => heading, "line" => line}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.schedule_scene(scope, script, %{heading: heading, line_no: line}) |> respond(socket)
  end

  def handle_event("schedule_remaining", _params, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.schedule_remaining(scope, script) |> respond(socket)
  end

  def handle_event("add_day", _params, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.add_day_break(scope, script) |> respond(socket)
  end

  def handle_event("update_day", %{"day_id" => id} = params, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    attrs = Map.take(params, ["shoot_date", "note"])
    Scripts.update_day_break(scope, script, id, attrs) |> respond(socket)
  end

  def handle_event("remove_item", %{"id" => id}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.remove_schedule_item(scope, script, id) |> respond(socket)
  end

  def handle_event("reorder", %{"order" => order}, socket) when is_list(order) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.reorder_schedule(scope, script, order) |> respond(socket)
  end

  def handle_event("move_item", %{"id" => id, "by" => by}, socket) do
    %{current_scope: scope, script: script, items: items} = socket.assigns
    ids = Enum.map(items, &to_string(&1.id))

    order =
      case Enum.find_index(ids, &(&1 == id)) do
        nil ->
          ids

        index ->
          target = index + if(by == "-1", do: -1, else: 1)

          if target < 0 or target >= length(ids),
            do: ids,
            else: ids |> List.delete_at(index) |> List.insert_at(target, id)
      end

    Scripts.reorder_schedule(scope, script, order) |> respond(socket)
  end

  defp respond({:error, :not_allowed}, socket),
    do: {:noreply, put_flash(socket, :error, "Only editors can change the stripboard.")}

  defp respond({:error, _}, socket),
    do: {:noreply, put_flash(socket, :error, "That didn't work - try again.")}

  defp respond(_ok, socket), do: {:noreply, reload_items(socket)}

  @impl true
  def handle_info({:schedule_changed, _id}, socket), do: {:noreply, reload_items(socket)}

  def handle_info({:breakdown_changed, _id}, socket) do
    {:noreply,
     socket
     |> assign(:tags, Scripts.list_breakdown_tags(socket.assigns.script))
     |> rebuild()}
  end

  def handle_info({:content_saved, _id, _user_id, content, version}, socket) do
    {:noreply,
     socket
     |> update(:script, &%{&1 | content: content, content_version: version})
     |> rebuild()}
  end

  def handle_info({:script_updated, _id}, socket) do
    {script, role} = Scripts.get_script!(socket.assigns.current_scope, socket.assigns.script.id)

    {:noreply,
     socket
     |> assign(script: script, role: role, page_title: "Stripboard · #{script.title}")
     |> rebuild()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Helpers

  @doc false
  # Strip colours follow the paper stripboard convention.
  def strip_class(%{int_ext: int_ext, time: time}) do
    night? =
      to_string(time)
      |> String.upcase()
      |> then(&Enum.any?(@night_times, fn t -> String.contains?(&1, t) end))

    case {int_ext, night?} do
      {:ext, false} -> "strip-ext-day"
      {:ext, true} -> "strip-ext-night"
      {:int_ext, false} -> "strip-ext-day"
      {:int_ext, true} -> "strip-ext-night"
      {:int, false} -> "strip-int-day"
      {:int, true} -> "strip-int-night"
      _ -> "strip-other"
    end
  end

  defp day_label(nil), do: nil
  defp day_label(%Date{} = date), do: Calendar.strftime(date, "%a %-d %b %Y")

  defp short_date(nil), do: nil
  defp short_date(%Date{} = date), do: Calendar.strftime(date, "%-d %b")

  defp code_class("SW"), do: "bg-success/15 text-success"
  defp code_class("SWF"), do: "bg-primary/15 text-primary"
  defp code_class("WF"), do: "bg-error/15 text-error"
  defp code_class("W"), do: "bg-base-200"
  defp code_class("H"), do: "bg-warning/15 text-warning"
  defp code_class(_), do: nil

  ## Render

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :can_edit, Scripts.can_edit?(assigns.role))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div class="py-2 print:py-0">
        <div class="flex flex-wrap items-center gap-3 print:hidden">
          <.link
            navigate={~p"/scripts/#{@script.id}"}
            class="rounded p-1.5 text-base-content/60 transition hover:bg-base-200"
            title="Back to the script"
          >
            <.icon name="hero-chevron-left" class="size-4" />
          </.link>
          <div class="min-w-0 flex-1">
            <h1 class="text-2xl font-semibold tracking-tight">Stripboard</h1>
            <p class="mt-0.5 truncate text-sm text-base-content/60">{@script.title}</p>
          </div>
          <.link
            id="open-production"
            navigate={~p"/scripts/#{@script.id}/production"}
            class="btn btn-ghost btn-sm"
            title="Tasks and calendar"
          >
            <.icon name="hero-clipboard-document-check" class="size-4" /><span class="hidden sm:inline">Production</span>
          </.link>
          <.link
            navigate={~p"/scripts/#{@script.id}/breakdown"}
            class="btn btn-ghost btn-sm"
            title="Breakdown"
          >
            <.icon name="hero-tag" class="size-4" /><span class="hidden sm:inline">Breakdown</span>
          </.link>
          <button
            type="button"
            onclick="window.print()"
            class="btn btn-ghost btn-sm"
            title="Print the stripboard"
          >
            <.icon name="hero-printer" class="size-4" /><span class="hidden sm:inline">Print</span>
          </button>
        </div>

        <div class="mt-6 hidden print:block">
          <h1 class="text-xl font-semibold">{@script.title} — Stripboard</h1>
        </div>

        <dl
          id="schedule-summary"
          class="mt-6 grid grid-cols-3 divide-x divide-base-300 rounded-lg border border-base-300 print:hidden"
        >
          <div class="px-4 py-3">
            <dt class="text-[11px] font-medium uppercase tracking-wider text-base-content/50">
              Shoot days
            </dt>
            <dd class="mt-0.5 text-xl font-semibold tabular-nums">
              {@board.days + if(@board.open_day, do: 1, else: 0)}
            </dd>
          </div>
          <div class="px-4 py-3">
            <dt class="text-[11px] font-medium uppercase tracking-wider text-base-content/50">
              Scheduled
            </dt>
            <dd class="mt-0.5 text-xl font-semibold tabular-nums">
              {eighths(@board.scheduled_eighths)} <span class="text-sm font-normal">pg</span>
            </dd>
          </div>
          <div class="px-4 py-3">
            <dt class="text-[11px] font-medium uppercase tracking-wider text-base-content/50">
              Unscheduled
            </dt>
            <dd class="mt-0.5 text-xl font-semibold tabular-nums">
              {length(@board.unscheduled)}
              <span class="text-sm font-normal text-base-content/60">
                scenes · {eighths(@board.unscheduled_eighths)} pg
              </span>
            </dd>
          </div>
        </dl>

        <div class="mt-6 inline-flex items-center gap-0.5 rounded-lg bg-base-200 p-0.5 print:hidden">
          <.link
            :for={
              {view, label, icon} <- [
                {"board", "Board", "hero-bars-3"},
                {"dood", "Day out of days", "hero-table-cells"}
              ]
            }
            id={"view-#{view}"}
            patch={
              if(view == "board",
                do: ~p"/scripts/#{@script.id}/schedule",
                else: ~p"/scripts/#{@script.id}/schedule?view=dood"
              )
            }
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

        <.dood_table :if={@view == "dood"} dood={@dood} script_id={@script.id} />

        <div :if={@view == "board"} class="mt-6 grid gap-6 lg:grid-cols-[minmax(0,1fr)_18rem]">
          <section>
            <div class="flex items-center justify-between gap-2 print:hidden">
              <h2 class="text-sm font-semibold">Board</h2>
              <button
                :if={@can_edit}
                id="add-day"
                type="button"
                phx-click="add_day"
                class="btn btn-ghost btn-xs"
              >
                <.icon name="hero-plus" class="size-3.5" /> End of day
              </button>
            </div>

            <div
              id="board"
              phx-hook=".Stripboard"
              data-can-edit={to_string(@can_edit)}
              class="mt-2 min-h-24 space-y-1 rounded-lg"
            >
              <div
                :if={@board.rows == []}
                id="board-empty"
                class="rounded-lg border border-dashed border-base-300 px-6 py-10 text-center text-sm text-base-content/50"
              >
                Nothing scheduled yet. Drag scenes here, or use <b>Schedule all</b>
                to lay them out in script order.
              </div>

              <%= for row <- @board.rows do %>
                <.strip_row :if={row.kind == :strip} row={row} can_edit={@can_edit} />
                <.day_row
                  :if={row.kind == :day}
                  row={row}
                  can_edit={@can_edit}
                  script_id={@script.id}
                  confirmed={length(Map.get(@confirmations, row.item.uid, []))}
                />
                <.missing_row :if={row.kind == :missing} row={row} can_edit={@can_edit} />
              <% end %>
            </div>

            <div
              :if={@board.open_day}
              id="open-day"
              class="mt-1 flex items-center justify-between rounded-md border border-dashed border-base-300 px-3 py-1.5 text-xs text-base-content/60"
            >
              <.link
                navigate={~p"/scripts/#{@script.id}/schedule/day/#{@board.open_day.day}"}
                class="underline-offset-2 hover:underline"
                title="Open this day's call sheet"
              >
                Day {@board.open_day.day} so far
              </.link>
              <span class="tabular-nums">
                {@board.open_day.scenes} {if @board.open_day.scenes == 1, do: "scene", else: "scenes"} · {eighths(
                  @board.open_day.eighths
                )} pg
              </span>
            </div>
          </section>

          <aside class="space-y-6 print:hidden">
            <section>
              <div class="flex items-center justify-between gap-2">
                <h2 class="text-sm font-semibold">Unscheduled</h2>
                <button
                  :if={@can_edit && @board.unscheduled != []}
                  id="schedule-remaining"
                  type="button"
                  phx-click="schedule_remaining"
                  class="btn btn-ghost btn-xs"
                >
                  Schedule all
                </button>
              </div>
              <div id="unscheduled" class="mt-2 space-y-1">
                <p
                  :if={@board.unscheduled == []}
                  class="rounded-lg border border-dashed border-base-300 px-3 py-4 text-center text-xs text-base-content/50"
                >
                  Every scene is on the board.
                </p>
                <div
                  :for={scene <- @board.unscheduled}
                  id={"unscheduled-#{scene.number}"}
                  draggable={to_string(@can_edit)}
                  data-heading={scene.heading}
                  data-line={scene.line}
                  class={[
                    "strip group flex items-center gap-2 rounded-md border py-1.5 pr-1.5 pl-3 text-xs",
                    strip_class(scene),
                    @can_edit && "cursor-grab active:cursor-grabbing"
                  ]}
                >
                  <span class="w-8 shrink-0 font-semibold tabular-nums">{scene_label(scene)}</span>
                  <span class="min-w-0 flex-1 truncate font-mono">{scene.heading}</span>
                  <span class="shrink-0 tabular-nums">{eighths(scene.eighths)}</span>
                  <button
                    :if={@can_edit}
                    type="button"
                    phx-click="schedule_scene"
                    phx-value-heading={scene.heading}
                    phx-value-line={scene.line}
                    class="rounded p-0.5 opacity-60 transition hover:bg-black/10 hover:opacity-100"
                    title="Add to the end of the board"
                  >
                    <.icon name="hero-plus" class="size-3.5" />
                  </button>
                </div>
              </div>
            </section>

            <section :if={@board.cast != []} id="cast-list">
              <h2 class="text-sm font-semibold">Cast</h2>
              <ol class="mt-2 space-y-0.5 text-xs">
                <li :for={{n, name} <- @board.cast} class="flex gap-2">
                  <span class="w-5 text-right font-semibold tabular-nums text-base-content/60">
                    {n}.
                  </span>
                  <span>{name}</span>
                </li>
              </ol>
            </section>
          </aside>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Stripboard">
        // Drag strips within the board, or from the Unscheduled column onto
        // it. Rows move in the page as you drag; on drop the new order goes
        // to the server, which re-renders the board from its own copy.
        export default {
          mounted() {
            if (this.el.dataset.canEdit !== "true") return
            this.unscheduled = document.getElementById("unscheduled")
            this.dragging = null
            this.onDragStart = (e) => {
              const row = e.target.closest("[draggable=true]")
              if (!row) return
              this.dragging = row
              this.origin = row.parentElement
              this.originNext = row.nextSibling
              row.classList.add("strip-dragging")
              e.dataTransfer.effectAllowed = "move"
              e.dataTransfer.setData("text/plain", row.id)
            }
            this.onDragEnd = () => {
              if (!this.dragging) return
              this.dragging.classList.remove("strip-dragging")
              // Dropped outside the board: put it back where it came from.
              if (!this.dropped) this.origin.insertBefore(this.dragging, this.originNext)
              this.dragging = null
              this.dropped = false
            }
            this.onDragOver = (e) => {
              if (!this.dragging) return
              e.preventDefault()
              const rows = [...this.el.querySelectorAll(":scope > [draggable=true]")]
                .filter((r) => r !== this.dragging)
              const after = rows.find((r) => {
                const box = r.getBoundingClientRect()
                return e.clientY < box.top + box.height / 2
              })
              document.getElementById("board-empty")?.remove()
              if (after) this.el.insertBefore(this.dragging, after)
              else this.el.appendChild(this.dragging)
            }
            this.onDrop = (e) => {
              if (!this.dragging) return
              e.preventDefault()
              this.dropped = true
              const order = [...this.el.querySelectorAll(":scope > [draggable=true]")].map((r) =>
                r.dataset.id ? r.dataset.id : { heading: r.dataset.heading, line_no: parseInt(r.dataset.line, 10) }
              )
              this.pushEvent("reorder", { order })
            }
            for (const list of [this.el, this.unscheduled]) {
              list?.addEventListener("dragstart", this.onDragStart)
              list?.addEventListener("dragend", this.onDragEnd)
            }
            this.el.addEventListener("dragover", this.onDragOver)
            this.el.addEventListener("drop", this.onDrop)
          },
          destroyed() {
            if (!this.onDragStart) return
            this.unscheduled?.removeEventListener("dragstart", this.onDragStart)
            this.unscheduled?.removeEventListener("dragend", this.onDragEnd)
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :dood, :map, required: true
  attr :script_id, :integer, required: true

  defp dood_table(assigns) do
    ~H"""
    <section id="dood" class="mt-6">
      <div
        :if={@dood.days == []}
        id="dood-empty"
        class="rounded-lg border border-dashed border-base-300 px-6 py-10 text-center text-sm text-base-content/50"
      >
        Put scenes on the board to see who works which day.
      </div>

      <div
        :if={@dood.days != []}
        class="inline-block max-w-full overflow-x-auto rounded-lg border border-base-300 align-top"
      >
        <table class="border-collapse text-xs">
          <thead class="bg-base-200">
            <tr>
              <th class="sticky left-0 z-10 min-w-40 bg-base-200 px-3 py-2 text-left font-semibold">
                Cast
              </th>
              <th :for={day <- @dood.days} class="min-w-12 px-1.5 py-2 text-center font-semibold">
                <.link
                  navigate={~p"/scripts/#{@script_id}/schedule/day/#{day.day}"}
                  class="underline-offset-2 hover:underline"
                  title="Call sheet"
                >
                  Day {day.day}
                </.link>
                <div :if={day.date} class="font-normal text-base-content/50">
                  {short_date(day.date)}
                </div>
              </th>
              <th
                class="border-l border-base-300 px-2 py-2 text-center font-semibold"
                title="Work days"
              >
                Work
              </th>
              <th class="px-2 py-2 text-center font-semibold" title="Hold days">Hold</th>
              <th class="px-2 py-2 text-center font-semibold" title="Work and hold">Total</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-200">
            <tr :for={row <- @dood.cast} id={"dood-#{row.number}"}>
              <th class="sticky left-0 z-10 bg-base-100 px-3 py-1.5 text-left font-medium whitespace-nowrap">
                <span class="mr-1 tabular-nums text-base-content/50">{row.number}.</span>{row.name}
              </th>
              <td :for={code <- row.codes} class="px-1 py-1 text-center">
                <span
                  :if={code}
                  class={["inline-block min-w-8 rounded px-1 py-0.5 font-semibold", code_class(code)]}
                >
                  {code}
                </span>
              </td>
              <td class="border-l border-base-300 px-2 text-center tabular-nums">{row.work}</td>
              <td class="px-2 text-center tabular-nums">{row.hold}</td>
              <td class="px-2 text-center font-semibold tabular-nums">{row.work + row.hold}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@dood.days != []} class="mt-3 text-xs text-base-content/50">
        SW start work · W work · WF work finish · SWF start and finish the same day · H hold
      </p>
    </section>
    """
  end

  attr :row, :map, required: true
  attr :can_edit, :boolean, required: true

  defp strip_row(assigns) do
    ~H"""
    <div
      id={"strip-#{@row.item.id}"}
      data-id={@row.item.id}
      draggable={to_string(@can_edit)}
      class={[
        "strip group grid grid-cols-[1.5rem_2.5rem_minmax(0,1fr)_2.5rem_auto] items-center gap-x-2 rounded-md border py-1.5 pr-1.5 pl-3 text-xs sm:grid-cols-[2rem_3.5rem_minmax(0,1fr)_5rem_3rem_7rem_auto] sm:gap-x-3",
        strip_class(@row.scene),
        @can_edit && "cursor-grab active:cursor-grabbing"
      ]}
    >
      <span class="font-semibold tabular-nums">{scene_label(@row.scene)}</span>
      <span class="font-medium">{int_ext_label(@row.scene.int_ext)}</span>
      <span class="min-w-0 truncate font-mono" title={@row.scene.heading}>
        {@row.scene.location}
      </span>
      <span class="hidden truncate sm:block">{@row.scene.time}</span>
      <span class="text-right tabular-nums">{eighths(@row.scene.eighths)}</span>
      <span class="hidden truncate tabular-nums sm:block" title="Cast">
        {Enum.join(@row.cast, ", ")}
      </span>
      <span
        :if={@can_edit}
        class="flex items-center transition focus-within:opacity-100 sm:opacity-0 sm:group-hover:opacity-100 print:hidden"
      >
        <.move_buttons id={@row.item.id} />
        <button
          type="button"
          phx-click="remove_item"
          phx-value-id={@row.item.id}
          class="rounded p-0.5 hover:bg-black/10"
          title="Back to unscheduled"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </span>
      <span :if={!@can_edit}></span>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :can_edit, :boolean, required: true
  attr :script_id, :integer, required: true
  attr :confirmed, :integer, default: 0

  defp day_row(assigns) do
    ~H"""
    <div
      id={"day-#{@row.item.id}"}
      data-id={@row.item.id}
      draggable={to_string(@can_edit)}
      class={[
        "group flex flex-wrap items-center gap-x-3 gap-y-1 rounded-md bg-neutral px-3 py-2 text-xs text-neutral-content",
        @can_edit && "cursor-grab active:cursor-grabbing"
      ]}
    >
      <.link
        navigate={~p"/scripts/#{@script_id}/schedule/day/#{@row.day}"}
        class="font-semibold uppercase tracking-wider underline-offset-2 hover:underline"
        title="Open this day's call sheet"
      >
        End of day {@row.day}
      </.link>
      <span class="tabular-nums opacity-80">
        {@row.scenes} {if @row.scenes == 1, do: "scene", else: "scenes"} · {eighths(@row.eighths)} pg
      </span>
      <span
        :if={@confirmed > 0}
        class="inline-flex items-center gap-0.5 rounded-full bg-white/15 px-1.5 text-[10px] tabular-nums"
        title="Confirmed the call sheet"
      >
        <.icon name="hero-check" class="size-3" />{@confirmed}
      </span>
      <span :if={!@can_edit && @row.item.shoot_date} class="opacity-80">
        {day_label(@row.item.shoot_date)}
      </span>
      <span :if={!@can_edit && @row.item.note} class="opacity-80">{@row.item.note}</span>

      <form
        :if={@can_edit}
        id={"day-form-#{@row.item.id}"}
        phx-change="update_day"
        class="ml-auto flex items-center gap-1.5"
      >
        <input type="hidden" name="day_id" value={@row.item.id} />
        <input
          type="date"
          name="shoot_date"
          value={@row.item.shoot_date}
          aria-label="Shoot date"
          class="rounded border border-white/20 bg-transparent px-1.5 py-0.5 text-xs [color-scheme:dark]"
        />
        <input
          type="text"
          name="note"
          value={@row.item.note}
          placeholder="Note"
          phx-debounce="600"
          maxlength="200"
          aria-label="Note"
          class="w-32 rounded border border-white/20 bg-transparent px-1.5 py-0.5 text-xs placeholder:text-neutral-content/40"
        />
      </form>
      <span
        :if={@can_edit}
        class="flex items-center transition focus-within:opacity-100 sm:opacity-0 sm:group-hover:opacity-100 print:hidden"
      >
        <.move_buttons id={@row.item.id} />
        <button
          type="button"
          phx-click="remove_item"
          phx-value-id={@row.item.id}
          class="rounded p-0.5 hover:bg-white/10"
          title="Remove this day break"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </span>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :can_edit, :boolean, required: true

  defp missing_row(assigns) do
    ~H"""
    <div
      id={"strip-#{@row.item.id}"}
      data-id={@row.item.id}
      draggable={to_string(@can_edit)}
      class="flex items-center gap-2 rounded-md border border-dashed border-error/50 px-3 py-1.5 text-xs text-error"
    >
      <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
      <span class="min-w-0 flex-1 truncate">
        No longer in the script: <span class="font-mono">{@row.item.heading}</span>
      </span>
      <button
        :if={@can_edit}
        type="button"
        phx-click="remove_item"
        phx-value-id={@row.item.id}
        class="rounded p-0.5 hover:bg-error/10"
        title="Remove this strip"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :id, :integer, required: true

  defp move_buttons(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="move_item"
      phx-value-id={@id}
      phx-value-by="-1"
      class="rounded p-0.5 hover:bg-black/10"
      title="Move up"
    >
      <.icon name="hero-chevron-up" class="size-3.5" />
    </button>
    <button
      type="button"
      phx-click="move_item"
      phx-value-id={@id}
      phx-value-by="1"
      class="rounded p-0.5 hover:bg-black/10"
      title="Move down"
    >
      <.icon name="hero-chevron-down" class="size-3.5" />
    </button>
    """
  end
end
