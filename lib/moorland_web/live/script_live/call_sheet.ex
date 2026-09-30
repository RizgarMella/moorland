defmodule MoorlandWeb.ScriptLive.CallSheet do
  @moduledoc """
  The call sheet for one shoot day, read off the stripboard: call times and
  location, the day's scenes, who is called or held (and, from the viewer's
  own contacts, who plays them), what each department needs, and the next
  day's scenes. Laid out to print on a page.

  Times and location are kept on the day's end-of-day break, so the open
  day at the end of the board is read-only until it is closed.
  """
  use MoorlandWeb, :live_view

  import MoorlandWeb.BreakdownComponents,
    only: [eighths: 1, int_ext_label: 1, category_dot: 1, scene_label: 1]

  alias Moorland.Contacts
  alias Moorland.Scripts
  alias Moorland.Scripts.{BreakdownTag, Schedule}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {script, role} = Scripts.get_script!(socket.assigns.current_scope, id)
    if connected?(socket), do: Scripts.subscribe(script.id)

    {:ok,
     assign(socket,
       script: script,
       role: role,
       contacts: contacts_by_role(socket.assigns.current_scope)
     )}
  end

  @impl true
  def handle_params(%{"day" => day}, _uri, socket) do
    day =
      case Integer.parse(day) do
        {n, ""} -> n
        _ -> 0
      end

    {:noreply, socket |> assign(:day_number, day) |> rebuild()}
  end

  defp rebuild(socket) do
    %{script: script, day_number: day} = socket.assigns

    board =
      Schedule.build(
        script.content,
        Scripts.list_breakdown_tags(script),
        Scripts.list_schedule_items(script)
      )

    sheet = Schedule.call_sheet(board, day)

    assign(socket,
      sheet: sheet,
      page_title:
        if(sheet,
          do: "Call sheet · Day #{sheet.index} · #{script.title}",
          else: "Call sheet · #{script.title}"
        )
    )
  end

  # Contacts whose role names a character, keyed by that name in capitals.
  defp contacts_by_role(scope) do
    scope
    |> Contacts.list_contacts()
    |> Enum.filter(&(is_binary(&1.role) and String.trim(&1.role) != ""))
    |> Map.new(&{&1.role |> String.trim() |> String.upcase(), &1})
  end

  ## Events

  @impl true
  def handle_event("update_calls", params, socket) do
    %{current_scope: scope, script: script, sheet: sheet} = socket.assigns

    with %{day: %{item: %{id: id}}} <- sheet do
      attrs = %{
        "crew_call" => blank_to_nil(params["crew_call"]),
        "shooting_call" => blank_to_nil(params["shooting_call"]),
        "location" => params["location"],
        "cast_calls" => params["cast_calls"] || %{}
      }

      case Scripts.update_day_break(scope, script, id, attrs) do
        {:ok, _} ->
          {:noreply, rebuild(socket)}

        {:error, :not_allowed} ->
          {:noreply, put_flash(socket, :error, "Only editors can change the call sheet.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Times use the 24-hour clock, like 07:30.")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @impl true
  def handle_info({event, _id}, socket)
      when event in [:schedule_changed, :breakdown_changed, :script_updated],
      do: {:noreply, rebuild(socket)}

  def handle_info({:content_saved, _id, _user_id, content, version}, socket) do
    {:noreply,
     socket
     |> update(:script, &%{&1 | content: content, content_version: version})
     |> rebuild()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Render

  defp long_date(nil), do: "Date to be set"
  defp long_date(%Date{} = date), do: Calendar.strftime(date, "%A %-d %B %Y")

  defp status_label("SW"), do: "Starts"
  defp status_label("SWF"), do: "Starts & finishes"
  defp status_label("WF"), do: "Finishes"
  defp status_label("W"), do: "Works"
  defp status_label("H"), do: "Hold"

  attr :contact, :any, required: true
  attr :character, :string, required: true

  defp played_by(assigns) do
    ~H"""
    <span :if={@contact}>{@contact.name}</span>
    <span :if={@contact && @contact.phone} class="ml-1 text-xs text-base-content/60">
      {@contact.phone}
    </span>
    <.link
      :if={!@contact}
      navigate={~p"/contacts"}
      class="text-xs text-base-content/40 hover:text-base-content print:hidden"
    >
      Add a contact with the role {@character}
    </.link>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        editable:
          Scripts.can_edit?(assigns.role) && assigns.sheet && assigns.sheet.day.item != nil
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div class="py-2 print:py-0">
        <div class="flex flex-wrap items-center gap-3 print:hidden">
          <.link
            navigate={~p"/scripts/#{@script.id}/schedule"}
            class="rounded p-1.5 text-base-content/60 transition hover:bg-base-200"
            title="Back to the stripboard"
          >
            <.icon name="hero-chevron-left" class="size-4" />
          </.link>
          <div class="min-w-0 flex-1">
            <h1 class="text-2xl font-semibold tracking-tight">Call sheet</h1>
            <p class="mt-0.5 truncate text-sm text-base-content/60">{@script.title}</p>
          </div>
          <div :if={@sheet} class="flex items-center gap-1">
            <.link
              :if={@sheet.prev}
              id="prev-day"
              patch={~p"/scripts/#{@script.id}/schedule/day/#{@sheet.prev.day}"}
              class="btn btn-ghost btn-sm"
              title="Previous shoot day"
            >
              <.icon name="hero-arrow-left" class="size-4" />
            </.link>
            <span class="text-sm tabular-nums text-base-content/60">
              {@sheet.index} / {@sheet.total}
            </span>
            <.link
              :if={@sheet.next}
              id="next-day"
              patch={~p"/scripts/#{@script.id}/schedule/day/#{@sheet.next.day}"}
              class="btn btn-ghost btn-sm"
              title="Next shoot day"
            >
              <.icon name="hero-arrow-right" class="size-4" />
            </.link>
          </div>
          <button
            type="button"
            onclick="window.print()"
            class="btn btn-ghost btn-sm"
            title="Print the call sheet"
          >
            <.icon name="hero-printer" class="size-4" /><span class="hidden sm:inline">Print</span>
          </button>
        </div>

        <div
          :if={!@sheet}
          id="no-such-day"
          class="mt-10 rounded-lg border border-dashed border-base-300 px-6 py-12 text-center"
        >
          <p class="text-sm font-medium">There's no shoot day {@day_number} on the stripboard.</p>
          <.link
            navigate={~p"/scripts/#{@script.id}/schedule"}
            class="mt-3 inline-block text-sm underline"
          >
            Open the stripboard
          </.link>
        </div>

        <article
          :if={@sheet}
          id="call-sheet"
          class="mt-6 overflow-hidden rounded-lg border border-base-300 print:mt-0 print:rounded-none print:border-black"
        >
          <header class="flex flex-wrap items-end justify-between gap-4 border-b border-base-300 bg-base-200/50 px-5 py-4 print:border-black print:bg-transparent">
            <div>
              <div class="text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
                {@script.title}
              </div>
              <div class="mt-1 text-2xl font-semibold tracking-tight">
                Day {@sheet.index} <span class="text-base-content/50">of {@sheet.total}</span>
              </div>
              <div class="mt-0.5 text-sm">{long_date(@sheet.day.date)}</div>
            </div>
            <div class="text-right text-sm">
              <div class="tabular-nums">
                {length(@sheet.day.scenes)} {if length(@sheet.day.scenes) == 1,
                  do: "scene",
                  else: "scenes"} · {eighths(@sheet.day.eighths)} pages
              </div>
              <div :if={@sheet.day.note} class="mt-0.5 text-base-content/60">{@sheet.day.note}</div>
            </div>
          </header>

          <form
            id="calls-form"
            phx-change="update_calls"
            class="divide-y divide-base-300 print:divide-black"
          >
            <div class="grid gap-4 px-5 py-4 sm:grid-cols-[8rem_8rem_minmax(0,1fr)]">
              <label class="block">
                <span class="text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
                  Crew call
                </span>
                <input
                  :if={@editable}
                  type="time"
                  name="crew_call"
                  value={@sheet.day.item.crew_call}
                  class="input input-bordered input-sm mt-1 w-full print:hidden"
                />
                <div
                  :if={@editable}
                  class="mt-1 hidden text-lg font-semibold tabular-nums print:block"
                >
                  {@sheet.day.item.crew_call || "—"}
                </div>
                <div :if={!@editable} class="mt-1 text-lg font-semibold tabular-nums">
                  {(@sheet.day.item && @sheet.day.item.crew_call) || "—"}
                </div>
              </label>
              <label class="block">
                <span class="text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
                  Shooting call
                </span>
                <input
                  :if={@editable}
                  type="time"
                  name="shooting_call"
                  value={@sheet.day.item.shooting_call}
                  class="input input-bordered input-sm mt-1 w-full print:hidden"
                />
                <div
                  :if={@editable}
                  class="mt-1 hidden text-lg font-semibold tabular-nums print:block"
                >
                  {@sheet.day.item.shooting_call || "—"}
                </div>
                <div :if={!@editable} class="mt-1 text-lg font-semibold tabular-nums">
                  {(@sheet.day.item && @sheet.day.item.shooting_call) || "—"}
                </div>
              </label>
              <label class="block">
                <span class="text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
                  Location
                </span>
                <input
                  :if={@editable}
                  type="text"
                  name="location"
                  value={@sheet.day.item.location}
                  placeholder="Address, parking, nearest hospital…"
                  phx-debounce="600"
                  maxlength="200"
                  class="input input-bordered input-sm mt-1 w-full print:hidden"
                />
                <div :if={@editable} class="mt-1 hidden text-sm print:block">
                  {@sheet.day.item.location || "—"}
                </div>
                <div :if={!@editable} class="mt-1 text-sm">
                  {(@sheet.day.item && @sheet.day.item.location) || "—"}
                </div>
              </label>
            </div>

            <p
              :if={Scripts.can_edit?(@role) && !@sheet.day.item}
              class="bg-warning/10 px-5 py-2 text-xs print:hidden"
            >
              This is the last day on the board and it has no end-of-day break yet. Add one on the stripboard to set times and a location.
            </p>

            <section class="px-5 py-4">
              <h2 class="text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
                Scenes
              </h2>
              <div class="mt-2 overflow-x-auto">
                <table id="call-scenes" class="w-full text-left text-sm">
                  <thead class="text-[11px] uppercase tracking-wider text-base-content/50">
                    <tr>
                      <th class="py-1 pr-3 font-medium">Sc</th>
                      <th class="py-1 pr-3 font-medium">Set</th>
                      <th class="py-1 pr-3 font-medium">D/N</th>
                      <th class="py-1 pr-3 text-right font-medium">Pages</th>
                      <th class="py-1 font-medium">Cast</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-base-200 print:divide-black/30">
                    <tr :for={scene <- @sheet.day.scenes} class="align-top">
                      <td class="py-1.5 pr-3 font-semibold tabular-nums">{scene_label(scene)}</td>
                      <td class="py-1.5 pr-3">
                        <div class="font-mono text-xs font-semibold">
                          {int_ext_label(scene.int_ext)}. {scene.location}
                        </div>
                        <div :if={scene.synopsis} class="mt-0.5 text-xs text-base-content/60">
                          {scene.synopsis}
                        </div>
                      </td>
                      <td class="py-1.5 pr-3 text-xs">{scene.time}</td>
                      <td class="py-1.5 pr-3 text-right tabular-nums">{eighths(scene.eighths)}</td>
                      <td class="py-1.5 text-xs tabular-nums">
                        {scene.elements |> Map.get("cast", []) |> Enum.map_join(", ", & &1.name)}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>

            <section :if={@sheet.cast != []} class="px-5 py-4">
              <h2 class="text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
                Cast
              </h2>
              <div class="mt-2 overflow-x-auto">
                <table id="call-cast" class="w-full text-left text-sm">
                  <thead class="text-[11px] uppercase tracking-wider text-base-content/50">
                    <tr>
                      <th class="py-1 pr-3 font-medium">#</th>
                      <th class="py-1 pr-3 font-medium">Character</th>
                      <th class="py-1 pr-3 font-medium">Played by</th>
                      <th class="py-1 pr-3 font-medium">Status</th>
                      <th class="py-1 font-medium">Call</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-base-200 print:divide-black/30">
                    <tr :for={member <- @sheet.cast} id={"call-cast-#{member.number}"}>
                      <td class="py-1.5 pr-3 tabular-nums text-base-content/60">{member.number}</td>
                      <td class="py-1.5 pr-3 font-medium">{member.name}</td>
                      <td class="py-1.5 pr-3">
                        <.played_by contact={@contacts[member.name]} character={member.name} />
                      </td>
                      <td class="py-1.5 pr-3 text-xs">
                        <span class={member.code == "H" && "text-warning"}>{status_label(member.code)}</span>
                      </td>
                      <td class="py-1.5">
                        <input
                          :if={@editable && member.code != "H"}
                          type="time"
                          name={"cast_calls[#{member.name}]"}
                          value={@sheet.day.item.cast_calls[member.name]}
                          aria-label={"Call time for #{member.name}"}
                          class="input input-bordered input-xs w-28 print:hidden"
                        />
                        <span
                          :if={@editable && member.code != "H"}
                          class="hidden tabular-nums print:inline"
                        >
                          {@sheet.day.item.cast_calls[member.name]}
                        </span>
                        <span :if={!@editable || member.code == "H"} class="tabular-nums">
                          {(@sheet.day.item && @sheet.day.item.cast_calls[member.name]) ||
                            if(member.code == "H", do: "—", else: "")}
                        </span>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>
          </form>

          <section
            :if={@sheet.departments != []}
            id="call-departments"
            class="border-t border-base-300 px-5 py-4 print:border-black"
          >
            <h2 class="text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
              Departments
            </h2>
            <dl class="mt-2 grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
              <div :for={{category, elements} <- @sheet.departments} class="flex gap-2">
                <dt class="flex w-32 shrink-0 items-center gap-1.5 text-xs font-medium">
                  <.category_dot category={category} />
                  {BreakdownTag.category_label(category)}
                </dt>
                <dd class="min-w-0">
                  {Enum.map_join(elements, ", ", fn el ->
                    "#{el.name} (#{Enum.map_join(el.scenes, ", ", &scene_label/1)})"
                  end)}
                </dd>
              </div>
            </dl>
          </section>

          <section
            :if={@sheet.next}
            id="advance-schedule"
            class="border-t border-base-300 bg-base-200/30 px-5 py-4 print:border-black print:bg-transparent"
          >
            <h2 class="text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
              Advance schedule · Day {@sheet.index + 1}<span :if={@sheet.next.date}> · {long_date(
                @sheet.next.date
              )}</span>
            </h2>
            <ul class="mt-2 space-y-0.5 text-sm">
              <li :for={scene <- @sheet.next.scenes} class="flex gap-3">
                <span class="w-8 font-semibold tabular-nums">{scene_label(scene)}</span>
                <span class="min-w-0 flex-1 truncate font-mono text-xs leading-5">{scene.heading}</span>
                <span class="tabular-nums text-base-content/60">{eighths(scene.eighths)}</span>
              </li>
            </ul>
          </section>
        </article>
      </div>
    </Layouts.app>
    """
  end
end
