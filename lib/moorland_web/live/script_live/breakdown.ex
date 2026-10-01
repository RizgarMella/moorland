defmodule MoorlandWeb.ScriptLive.Breakdown do
  @moduledoc """
  The script breakdown: a sheet per scene (cast, background, props and every
  other department, with page count, INT/EXT and time of day) and a
  department view listing each element with the scenes it appears in.

  Tags are made by highlighting words in the editor's preview, or here by
  adding an element to a scene. Cast who speak are filled in automatically.
  """
  use MoorlandWeb, :live_view

  import MoorlandWeb.BreakdownComponents

  alias Moorland.Scripts
  alias Moorland.Scripts.{Breakdown, BreakdownTag}

  @tabs ~w(scenes departments)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {script, role} = Scripts.get_script!(socket.assigns.current_scope, id)
    if connected?(socket), do: Scripts.subscribe(script.id)

    {:ok,
     socket
     |> assign(
       script: script,
       role: role,
       page_title: "Breakdown · #{script.title}",
       editing: nil,
       tags: Scripts.list_breakdown_tags(script)
     )
     |> rebuild()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "scenes"
    {:noreply, assign(socket, :tab, tab)}
  end

  defp rebuild(socket) do
    %{script: script, tags: tags} = socket.assigns
    breakdown = Breakdown.build(script.content, tags)

    assign(socket,
      breakdown: breakdown,
      departments: Breakdown.departments(breakdown),
      total_eighths: breakdown.scenes |> Enum.map(& &1.eighths) |> Enum.sum()
    )
  end

  defp reload_tags(socket) do
    socket
    |> assign(:tags, Scripts.list_breakdown_tags(socket.assigns.script))
    |> rebuild()
  end

  ## Events

  @impl true
  def handle_event("add_element", params, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    # Anchored to the heading's words, so the tag stays with its scene when
    # scenes above it grow, shrink or move.
    attrs = %{
      category: params["category"],
      name: params["name"],
      anchor_text: params["heading"],
      line_no: params["line"]
    }

    case Scripts.create_breakdown_tag(scope, script, attrs) do
      {:ok, _tag} ->
        {:noreply, reload_tags(socket)}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "You can't tag this script.")}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Give the element a name.")}
    end
  end

  def handle_event("remove_tags", %{"ids" => ids}, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    results =
      ids
      |> String.split(",", trim: true)
      |> Enum.map(&Scripts.delete_breakdown_tag(scope, script, &1))

    socket =
      if Enum.any?(results, &(&1 != :ok)),
        do: put_flash(socket, :error, "Some of those tags are someone else's to remove."),
        else: socket

    {:noreply, reload_tags(socket)}
  end

  def handle_event("edit_element", %{"category" => category, "key" => key}, socket) do
    {:noreply, assign(socket, :editing, {category, key})}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing, nil)}
  end

  def handle_event("save_element", params, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    attrs = %{name: params["name"], category: params["new_category"]}

    case Scripts.update_breakdown_element(scope, script, params["category"], params["key"], attrs) do
      {:ok, _count} ->
        {:noreply, socket |> assign(:editing, nil) |> reload_tags()}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "Only editors can rename elements.")}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Give the element a name.")}
    end
  end

  @impl true
  def handle_info({:breakdown_changed, _id}, socket), do: {:noreply, reload_tags(socket)}

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
     |> assign(script: script, role: role, page_title: "Breakdown · #{script.title}")
     |> rebuild()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Helpers

  defp can_tag?(role), do: Scripts.can_comment?(role)

  defp element_count(breakdown) do
    breakdown.scenes
    |> Enum.flat_map(fn scene ->
      Enum.flat_map(scene.elements, fn {cat, entries} -> Enum.map(entries, &{cat, &1.key}) end)
    end)
    |> Enum.uniq()
    |> length()
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} section={:scripts} wide>
      <div class="py-2 print:py-0">
        <MoorlandWeb.ProductionComponents.production_header
          script={@script}
          current={:breakdown}
          title="Breakdown"
        >
          <:actions>
            <a
              id="breakdown-csv"
              href={~p"/scripts/#{@script.id}/breakdown.csv"}
              class="btn btn-ghost btn-sm"
              title="Download as a spreadsheet (CSV)"
            >
              <.icon name="hero-table-cells" class="size-4" /><span class="hidden sm:inline">CSV</span>
            </a>
            <button
              id="breakdown-print"
              type="button"
              onclick="window.print()"
              class="btn btn-ghost btn-sm"
              title="Print or save as PDF"
            >
              <.icon name="hero-printer" class="size-4" /><span class="hidden sm:inline">Print</span>
            </button>
          </:actions>
        </MoorlandWeb.ProductionComponents.production_header>

        <div class="mt-6 hidden print:block">
          <h1 class="text-xl font-semibold">{@script.title} — Breakdown</h1>
        </div>

        <dl
          id="breakdown-summary"
          class="mt-6 grid grid-cols-3 divide-x divide-base-300 rounded-lg border border-base-300 print:hidden"
        >
          <div class="px-4 py-3">
            <dt class="text-[11px] font-medium uppercase tracking-wider text-base-content/50">
              Scenes
            </dt>
            <dd class="mt-0.5 text-xl font-semibold tabular-nums">{length(@breakdown.scenes)}</dd>
          </div>
          <div class="px-4 py-3">
            <dt class="text-[11px] font-medium uppercase tracking-wider text-base-content/50">
              Pages
            </dt>
            <dd class="mt-0.5 text-xl font-semibold tabular-nums">{eighths(@total_eighths)}</dd>
          </div>
          <div class="px-4 py-3">
            <dt class="text-[11px] font-medium uppercase tracking-wider text-base-content/50">
              Elements
            </dt>
            <dd class="mt-0.5 text-xl font-semibold tabular-nums">{element_count(@breakdown)}</dd>
          </div>
        </dl>

        <div class="mt-6 flex items-center gap-4 print:hidden">
          <div class="flex items-center gap-0.5 rounded-lg bg-base-200 p-0.5">
            <.link
              :for={
                {tab, label, icon} <- [
                  {"scenes", "Scene sheets", "hero-document-text"},
                  {"departments", "Departments", "hero-squares-2x2"}
                ]
              }
              id={"tab-#{tab}"}
              patch={~p"/scripts/#{@script.id}/breakdown?tab=#{tab}"}
              class={[
                "flex items-center gap-1.5 rounded-md px-3 py-1 text-xs font-medium transition",
                @tab == tab && "bg-base-100 shadow-sm",
                @tab != tab && "text-base-content/60 hover:text-base-content"
              ]}
            >
              <.icon name={icon} class="size-4" />
              {label}
            </.link>
          </div>
          <p :if={can_tag?(@role)} class="hidden text-xs text-base-content/50 sm:block">
            Tip: highlight words in the script preview and choose <b>Tag</b>.
          </p>
        </div>

        <div
          :if={@breakdown.scenes == []}
          id="breakdown-empty"
          class="mt-10 rounded-lg border border-dashed border-base-300 px-6 py-12 text-center"
        >
          <.icon name="hero-film" class="size-8 text-base-content/30" />
          <p class="mt-3 text-sm font-medium">No scenes yet</p>
          <p class="mt-1 text-sm text-base-content/60">
            Scene headings like <code>INT. KITCHEN - NIGHT</code> start the breakdown.
          </p>
        </div>

        <.unplaced
          :if={@breakdown.unplaced != []}
          tags={@breakdown.unplaced}
          role={@role}
          user_id={@current_scope.user.id}
        />

        <div
          :if={@tab == "scenes" && @breakdown.scenes != []}
          id="scene-sheets"
          phx-hook=".ScrollToScene"
          class="bd-print-sheets mt-6 space-y-4"
        >
          <.sheet
            :for={scene <- @breakdown.scenes}
            scene={scene}
            role={@role}
            user_id={@current_scope.user.id}
          />
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToScene">
          // A scene link from the Departments tab patches back to this tab
          // with #scene-N; the sheets are rendered after LiveView's own
          // scroll-to-hash has run, so scroll once they are in the page.
          export default {
            mounted() {
              const id = decodeURIComponent(window.location.hash.slice(1))
              const target = id && document.getElementById(id)
              if (target) target.scrollIntoView({block: "start"})
            }
          }
        </script>

        <div
          :if={@tab == "departments" && @breakdown.scenes != []}
          id="departments"
          class="mt-6 grid gap-4 sm:grid-cols-2"
        >
          <.department
            :for={{category, elements} <- @departments}
            category={category}
            elements={elements}
            editing={@editing}
            role={@role}
            script={@script}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :scene, :map, required: true
  attr :role, :atom, required: true
  attr :user_id, :integer, required: true

  defp sheet(assigns) do
    ~H"""
    <section
      id={"scene-#{@scene.number}"}
      class="bd-sheet scroll-mt-6 overflow-hidden rounded-lg border border-base-300 bg-base-100"
    >
      <header class="flex flex-wrap items-center gap-x-4 gap-y-1 border-b border-base-300 bg-base-200/50 px-4 py-2.5">
        <span class="flex size-7 items-center justify-center rounded-md bg-neutral text-xs font-semibold tabular-nums text-neutral-content">
          {scene_label(@scene)}
        </span>
        <h2 class="min-w-0 flex-1 truncate font-mono text-sm font-semibold">{@scene.heading}</h2>
        <div class="flex items-center gap-3 text-[11px] font-medium uppercase tracking-wider text-base-content/60">
          <span title="Interior or exterior">{int_ext_label(@scene.int_ext)}</span>
          <span :if={@scene.time} title="Time of day">{@scene.time}</span>
          <span title="Length in pages" class="tabular-nums normal-case">
            {eighths(@scene.eighths)} pg
          </span>
        </div>
      </header>

      <div class="grid gap-x-6 gap-y-4 p-4 sm:grid-cols-2 lg:grid-cols-3">
        <div
          :for={{category, entries} <- ordered_elements(@scene.elements)}
          class={"bd-cat-#{category}"}
        >
          <h3 class="bd-rule pt-1.5 text-[11px] font-semibold uppercase tracking-wider text-base-content/60">
            {BreakdownTag.category_label(category)}
          </h3>
          <ul class="mt-1.5 flex flex-wrap gap-1.5">
            <li
              :for={entry <- entries}
              class="bd-chip group inline-flex items-center gap-1 rounded-md border px-2 py-0.5 text-xs transition"
            >
              <span>{entry.name}</span>
              <span
                :if={entry.auto}
                class="text-[10px] text-base-content/40"
                title="Speaks in this scene"
              >
                speaks
              </span>
              <button
                :if={removable_ids(entry, @role, @user_id) != ""}
                type="button"
                phx-click="remove_tags"
                phx-value-ids={removable_ids(entry, @role, @user_id)}
                class="-mr-1 rounded p-0.5 text-base-content/30 opacity-0 transition group-hover:opacity-100 hover:text-error focus:opacity-100 print:hidden"
                title={"Untag #{entry.name} in this scene"}
              >
                <.icon name="hero-x-mark" class="size-3" />
              </button>
            </li>
          </ul>
        </div>

        <p
          :if={@scene.elements == %{}}
          class="text-sm text-base-content/40 sm:col-span-2 lg:col-span-3"
        >
          Nothing tagged in this scene yet.
        </p>
      </div>

      <form
        :if={can_tag?(@role)}
        id={"add-element-#{@scene.number}"}
        phx-submit="add_element"
        class="flex flex-wrap items-center gap-2 border-t border-base-200 px-4 py-2.5 print:hidden"
      >
        <input type="hidden" name="line" value={@scene.line} />
        <input type="hidden" name="heading" value={@scene.heading} />
        <select name="category" class="select select-bordered select-xs w-40" aria-label="Category">
          <option
            :for={{key, label} <- BreakdownTag.categories()}
            value={key}
            selected={key == "props"}
          >
            {label}
          </option>
        </select>
        <input
          type="text"
          name="name"
          required
          maxlength="120"
          autocomplete="off"
          placeholder="Add an element to this scene"
          class="input input-bordered input-xs min-w-40 flex-1"
        />
        <button type="submit" class="btn btn-ghost btn-xs">
          <.icon name="hero-plus" class="size-3.5" /> Add
        </button>
      </form>
    </section>
    """
  end

  attr :category, :string, required: true
  attr :elements, :list, required: true
  attr :editing, :any, required: true
  attr :role, :atom, required: true
  attr :script, :map, required: true

  defp department(assigns) do
    ~H"""
    <section
      id={"dept-#{@category}"}
      class={["bd-sheet rounded-lg border border-base-300 p-4", "bd-cat-#{@category}"]}
    >
      <h2 class="flex items-center justify-between gap-2 text-sm font-semibold">
        <.category_label category={@category} />
        <span class="text-xs font-normal tabular-nums text-base-content/50">
          {length(@elements)}
        </span>
      </h2>

      <p :if={@elements == []} class="mt-2 text-xs text-base-content/40">Nothing tagged.</p>

      <ul :if={@elements != []} class="mt-2 divide-y divide-base-200">
        <li :for={el <- @elements} class="group py-1.5">
          <form
            :if={@editing == {@category, el.key}}
            id={"edit-element-#{@category}-#{el.key}"}
            phx-submit="save_element"
            class="flex flex-wrap items-center gap-1.5"
          >
            <input type="hidden" name="category" value={@category} />
            <input type="hidden" name="key" value={el.key} />
            <input
              type="text"
              name="name"
              value={el.name}
              required
              maxlength="120"
              class="input input-bordered input-xs min-w-32 flex-1"
            />
            <select name="new_category" class="select select-bordered select-xs w-36">
              <option
                :for={{key, label} <- BreakdownTag.categories()}
                value={key}
                selected={key == @category}
              >
                {label}
              </option>
            </select>
            <button type="submit" class="btn btn-neutral btn-xs">Save</button>
            <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-xs">
              Cancel
            </button>
          </form>

          <div :if={@editing != {@category, el.key}} class="flex items-start gap-2">
            <span class="min-w-0 flex-1 text-sm">{el.name}</span>
            <span class="flex flex-wrap justify-end gap-1">
              <.link
                :for={scene <- el.scenes}
                patch={~p"/scripts/#{@script.id}/breakdown?tab=scenes" <> "#scene-#{scene.number}"}
                class="rounded bg-base-200 px-1.5 text-[11px] tabular-nums text-base-content/70 transition hover:bg-base-300"
                title={"Scene #{scene_label(scene)}"}
              >
                {scene_label(scene)}
              </.link>
            </span>
            <button
              :if={Scripts.can_edit?(@role) && el.tagged}
              type="button"
              phx-click="edit_element"
              phx-value-category={@category}
              phx-value-key={el.key}
              class="rounded p-0.5 text-base-content/30 opacity-0 transition group-hover:opacity-100 hover:text-base-content focus:opacity-100 print:hidden"
              title="Rename or recategorise"
            >
              <.icon name="hero-pencil" class="size-3.5" />
            </button>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  attr :tags, :list, required: true
  attr :role, :atom, required: true
  attr :user_id, :integer, required: true

  defp unplaced(assigns) do
    ~H"""
    <section
      id="unplaced-tags"
      class="mt-6 rounded-lg border border-warning/40 bg-warning/5 p-4 print:hidden"
    >
      <h2 class="flex items-center gap-2 text-sm font-semibold">
        <.icon name="hero-exclamation-triangle" class="size-4 text-warning" />
        Tags whose words have left the script
      </h2>
      <p class="mt-1 text-xs text-base-content/60">
        The text these were tagged on has been rewritten or cut. Remove them, or tag the new words.
      </p>
      <ul class="mt-3 flex flex-wrap gap-1.5">
        <li
          :for={tag <- @tags}
          class={[
            "bd-chip inline-flex items-center gap-1.5 rounded-md border px-2 py-0.5 text-xs",
            "bd-cat-#{tag.category}"
          ]}
        >
          <.category_dot category={tag.category} />
          <span>{tag.name}</span>
          <span :if={tag.anchor_text} class="text-base-content/40">“{tag.anchor_text}”</span>
          <button
            :if={tag.author_id == @user_id or Scripts.can_edit?(@role)}
            type="button"
            phx-click="remove_tags"
            phx-value-ids={tag.id}
            class="rounded p-0.5 text-base-content/40 hover:text-error"
            title="Remove this tag"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </li>
      </ul>
    </section>
    """
  end
end
