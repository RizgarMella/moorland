defmodule MoorlandWeb.ScriptLive.Shots do
  @moduledoc """
  The shot list: every scene's shots, numbered 12A, 12B, with size, angle,
  movement, lens and description. Shots are made here or by highlighting
  words in the editor's preview and choosing Shot; either way they stay
  with their words as the script changes. Prints as a plain list.
  """
  use MoorlandWeb, :live_view

  import MoorlandWeb.BreakdownComponents, only: [scene_label: 1]

  alias Moorland.Scripts
  alias Moorland.Scripts.{Shot, ShotList}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {script, role} = Scripts.get_script!(socket.assigns.current_scope, id)
    if connected?(socket), do: Scripts.subscribe(script.id)

    {:ok,
     socket
     |> assign(script: script, role: role, page_title: "Shot list · #{script.title}")
     |> reload()}
  end

  defp reload(socket) do
    %{script: script} = socket.assigns
    assign(socket, :list, ShotList.build(script.content, Scripts.list_shots(script)))
  end

  ## Events

  @impl true
  def handle_event("add_shot", params, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    attrs = %{
      anchor_text: params["heading"],
      line_no: params["line"],
      size: blank_to_nil(params["size"]),
      description: params["description"] || ""
    }

    Scripts.create_shot(scope, script, attrs) |> respond(socket)
  end

  def handle_event("update_shot", %{"shot_id" => id} = params, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    attrs =
      params
      |> Map.take(~w(size angle movement lens description))
      |> Map.new(fn {k, v} ->
        {k, if(k in ~w(size angle movement), do: blank_to_nil(v), else: v)}
      end)

    Scripts.update_shot(scope, script, id, attrs) |> respond(socket)
  end

  def handle_event("swap_shots", %{"id" => id, "other" => other}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.swap_shots(scope, script, id, other) |> respond(socket)
  end

  def handle_event("delete_shot", %{"id" => id}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.delete_shot(scope, script, id) |> respond(socket)
  end

  defp respond({:error, :not_allowed}, socket),
    do: {:noreply, put_flash(socket, :error, "That shot is someone else's to change.")}

  defp respond({:error, %Ecto.Changeset{}}, socket),
    do: {:noreply, put_flash(socket, :error, "That shot couldn't be saved.")}

  defp respond({:error, _}, socket), do: {:noreply, reload(socket)}
  defp respond(_ok, socket), do: {:noreply, reload(socket)}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @impl true
  def handle_info({:shots_changed, _id}, socket), do: {:noreply, reload(socket)}

  def handle_info({:content_saved, _id, _user_id, content, version}, socket) do
    {:noreply,
     socket
     |> update(:script, &%{&1 | content: content, content_version: version})
     |> reload()}
  end

  def handle_info({:script_updated, _id}, socket) do
    {script, role} = Scripts.get_script!(socket.assigns.current_scope, socket.assigns.script.id)
    {:noreply, socket |> assign(script: script, role: role) |> reload()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Render

  # A shot added from this page is anchored to its scene's heading; saying
  # so under the scene's own header is noise.
  defp same_words?(a, b),
    do: Moorland.Scripts.Breakdown.normalize(a) == Moorland.Scripts.Breakdown.normalize(b)

  defp can_change?(shot, role, user_id),
    do: shot.author_id == user_id or Scripts.can_edit?(role)

  @impl true
  def render(assigns) do
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
            <h1 class="text-2xl font-semibold tracking-tight">Shot list</h1>
            <p class="mt-0.5 truncate text-sm text-base-content/60">
              {@script.title} · {@list.total} {if @list.total == 1, do: "shot", else: "shots"}
            </p>
          </div>
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
            title="Print the shot list"
          >
            <.icon name="hero-printer" class="size-4" /><span class="hidden sm:inline">Print</span>
          </button>
        </div>

        <h1 class="hidden text-xl font-semibold print:block">{@script.title} — Shot list</h1>

        <p
          :if={Scripts.can_comment?(@role)}
          class="mt-4 text-xs text-base-content/50 print:hidden"
        >
          Tip: highlight words in the script preview and choose <b>Shot</b>
          to plan a shot on exactly that moment.
        </p>

        <div
          :if={@list.scenes == []}
          id="shots-empty"
          class="mt-8 rounded-lg border border-dashed border-base-300 px-6 py-12 text-center text-sm text-base-content/50"
        >
          Scene headings start the shot list.
        </div>

        <section
          :if={@list.unplaced != []}
          id="unplaced-shots"
          class="mt-6 rounded-lg border border-warning/40 bg-warning/5 p-4 print:hidden"
        >
          <h2 class="flex items-center gap-2 text-sm font-semibold">
            <.icon name="hero-exclamation-triangle" class="size-4 text-warning" />
            Shots whose words have left the script
          </h2>
          <ul class="mt-2 space-y-1 text-sm">
            <li :for={shot <- @list.unplaced} class="flex items-center gap-2">
              <span class="min-w-0 flex-1 truncate">
                {shot.description}
                <span :if={shot.anchor_text} class="text-base-content/40">“{shot.anchor_text}”</span>
              </span>
              <button
                :if={can_change?(shot, @role, @current_scope.user.id)}
                type="button"
                phx-click="delete_shot"
                phx-value-id={shot.id}
                class="rounded p-0.5 text-base-content/40 hover:text-error"
                title="Remove this shot"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </li>
          </ul>
        </section>

        <div class="mt-6 space-y-3">
          <section
            :for={scene <- @list.scenes}
            id={"shots-scene-#{scene.number}"}
            class={[
              "bd-sheet overflow-hidden rounded-lg border border-base-300",
              scene.shots == [] && "print:hidden"
            ]}
          >
            <header class="flex items-center gap-3 border-b border-base-300 bg-base-200/50 px-4 py-2">
              <span class="flex h-6 min-w-6 items-center justify-center rounded-md bg-neutral px-1 text-xs font-semibold tabular-nums text-neutral-content">
                {scene_label(scene)}
              </span>
              <h2 class="min-w-0 flex-1 truncate font-mono text-sm font-semibold">{scene.heading}</h2>
              <span class="text-xs tabular-nums text-base-content/50">
                {length(scene.shots)} {if length(scene.shots) == 1, do: "shot", else: "shots"}
              </span>
            </header>

            <div :if={scene.shots != []} class="divide-y divide-base-200">
              <.shot_row
                :for={{shot, i} <- Enum.with_index(scene.shots)}
                shot={shot}
                heading={scene.heading}
                prev={i > 0 && Enum.at(scene.shots, i - 1)}
                next={Enum.at(scene.shots, i + 1)}
                editable={can_change?(shot, @role, @current_scope.user.id)}
              />
            </div>

            <form
              :if={Scripts.can_comment?(@role)}
              id={"add-shot-#{scene.number}"}
              phx-submit="add_shot"
              class="flex flex-wrap items-center gap-2 border-t border-base-200 px-4 py-2 print:hidden"
            >
              <input type="hidden" name="line" value={scene.line} />
              <input type="hidden" name="heading" value={scene.heading} />
              <select name="size" class="select select-bordered select-xs w-28" aria-label="Size">
                <option value="">Size</option>
                <option :for={size <- Shot.sizes()} value={size}>{size}</option>
              </select>
              <input
                type="text"
                name="description"
                maxlength="2000"
                autocomplete="off"
                placeholder="Add a shot to this scene"
                class="input input-bordered input-xs min-w-40 flex-1"
              />
              <button type="submit" class="btn btn-ghost btn-xs">
                <.icon name="hero-plus" class="size-3.5" /> Add
              </button>
            </form>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :shot, :map, required: true
  attr :heading, :string, required: true
  attr :prev, :any, required: true
  attr :next, :any, required: true
  attr :editable, :boolean, required: true

  defp shot_row(assigns) do
    ~H"""
    <div id={"shot-#{@shot.id}"} class="group flex items-start gap-3 px-4 py-2">
      <span class="w-12 shrink-0 pt-1 text-sm font-semibold tabular-nums">{@shot.number}</span>

      <form
        :if={@editable}
        id={"shot-form-#{@shot.id}"}
        phx-change="update_shot"
        class="grid min-w-0 flex-1 gap-1.5 sm:grid-cols-[6rem_6rem_7rem_5rem_minmax(0,1fr)] print:hidden"
      >
        <input type="hidden" name="shot_id" value={@shot.id} />
        <.choice name="size" value={@shot.size} options={Shot.sizes()} label="Size" />
        <.choice name="angle" value={@shot.angle} options={Shot.angles()} label="Angle" />
        <.choice name="movement" value={@shot.movement} options={Shot.movements()} label="Movement" />
        <input
          type="text"
          name="lens"
          value={@shot.lens}
          placeholder="Lens"
          maxlength="40"
          phx-debounce="600"
          aria-label="Lens"
          class="input input-bordered input-xs w-full"
        />
        <input
          type="text"
          name="description"
          value={@shot.description}
          placeholder="What we see"
          maxlength="2000"
          phx-debounce="600"
          aria-label="Description"
          class="input input-bordered input-xs w-full"
        />
      </form>

      <div class={["min-w-0 flex-1 text-sm", @editable && "hidden print:block"]}>
        <div class="flex flex-wrap gap-x-2">
          <span class="font-medium">
            {Enum.reject([@shot.size, @shot.angle, @shot.movement, @shot.lens], &(&1 in [nil, ""]))
            |> Enum.join(" · ")}
          </span>
          <span :if={@shot.description != ""}>{@shot.description}</span>
        </div>
        <div
          :if={@shot.anchor_text && !same_words?(@shot.anchor_text, @heading)}
          class="text-[11px] text-base-content/40"
        >
          on “{@shot.anchor_text}”
        </div>
      </div>

      <div
        :if={@editable}
        class="flex shrink-0 items-center transition sm:opacity-0 sm:group-hover:opacity-100 focus-within:opacity-100 print:hidden"
      >
        <button
          :if={@prev}
          type="button"
          phx-click="swap_shots"
          phx-value-id={@shot.id}
          phx-value-other={@prev.id}
          class="rounded p-0.5 hover:bg-base-200"
          title="Move up"
        >
          <.icon name="hero-chevron-up" class="size-3.5" />
        </button>
        <button
          :if={@next}
          type="button"
          phx-click="swap_shots"
          phx-value-id={@shot.id}
          phx-value-other={@next.id}
          class="rounded p-0.5 hover:bg-base-200"
          title="Move down"
        >
          <.icon name="hero-chevron-down" class="size-3.5" />
        </button>
        <button
          type="button"
          phx-click="delete_shot"
          phx-value-id={@shot.id}
          class="rounded p-0.5 text-base-content/40 hover:text-error"
          title="Delete this shot"
        >
          <.icon name="hero-trash" class="size-3.5" />
        </button>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :options, :list, required: true
  attr :label, :string, required: true

  defp choice(assigns) do
    ~H"""
    <select name={@name} aria-label={@label} class="select select-bordered select-xs w-full">
      <option value="">{@label}</option>
      <option :for={option <- @options} value={option} selected={option == @value}>
        {if @name == "size", do: "#{option} · #{Shot.size_label(option)}", else: option}
      </option>
    </select>
    """
  end
end
