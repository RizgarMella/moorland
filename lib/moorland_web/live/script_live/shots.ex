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
     |> assign(
       script: script,
       role: role,
       page_title: "Shot list · #{script.title}",
       image_target: nil
     )
     |> allow_upload(:image,
       accept: ~w(.jpg .jpeg .png .webp),
       max_entries: 1,
       max_file_size: 5_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )
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

  def handle_event("pick_image", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {id, ""} -> {:noreply, assign(socket, :image_target, id)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_image", _params, socket) do
    socket =
      Enum.reduce(
        socket.assigns.uploads.image.entries,
        socket,
        &cancel_upload(&2, :image, &1.ref)
      )

    {:noreply, assign(socket, :image_target, nil)}
  end

  def handle_event("validate_image", _params, socket), do: {:noreply, socket}

  def handle_event("remove_image", %{"id" => id}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.remove_shot_image(scope, script, id) |> respond(socket)
  end

  # An image is attached the moment it finishes uploading.
  defp handle_progress(:image, entry, socket) do
    if entry.done? do
      %{current_scope: scope, script: script, image_target: target} = socket.assigns

      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok,
           Scripts.attach_shot_image(scope, script, target, path, Path.extname(entry.client_name))}
        end)

      socket = assign(socket, :image_target, nil)

      case result do
        {:ok, _} -> {:noreply, reload(socket)}
        other -> respond(other, socket)
      end
    else
      {:noreply, socket}
    end
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

  defp upload_error(:too_large), do: "Images up to 5 MB."
  defp upload_error(:not_accepted), do: "JPEG, PNG or WebP only."
  defp upload_error(:too_many_files), do: "One image at a time."
  defp upload_error(_), do: "That upload failed."

  defp can_change?(shot, role, user_id),
    do: shot.author_id == user_id or Scripts.can_edit?(role)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} section={:scripts} wide>
      <div class="py-2 print:py-0">
        <MoorlandWeb.ProductionComponents.production_header
          script={@script}
          current={:shots}
          title="Shot list"
        >
          <:subtitle>
            {@list.total} {if @list.total == 1, do: "shot", else: "shots"}
          </:subtitle>
          <:actions>
            <button
              type="button"
              onclick="window.print()"
              class="btn btn-ghost btn-sm"
              title="Print the shot list"
            >
              <.icon name="hero-printer" class="size-4" /><span class="hidden sm:inline">Print</span>
            </button>
          </:actions>
        </MoorlandWeb.ProductionComponents.production_header>

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
                script_id={@script.id}
                image_target={@image_target}
                uploads={@uploads}
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
  attr :script_id, :integer, required: true
  attr :image_target, :any, required: true
  attr :uploads, :map, required: true
  attr :prev, :any, required: true
  attr :next, :any, required: true
  attr :editable, :boolean, required: true

  defp shot_row(assigns) do
    ~H"""
    <div id={"shot-#{@shot.id}"} class="group flex flex-wrap items-start gap-3 px-4 py-2">
      <span class="w-12 shrink-0 pt-1 text-sm font-semibold tabular-nums">{@shot.number}</span>

      <div :if={@shot.image || @editable} class="w-32 shrink-0">
        <img
          :if={@shot.image}
          src={~p"/scripts/#{@script_id}/shots/#{@shot.id}/image?v=#{@shot.image}"}
          alt={"Storyboard frame for shot #{@shot.number}"}
          class="aspect-video w-32 rounded border border-base-300 bg-base-200 object-cover"
        />
        <button
          :if={!@shot.image && @editable && @image_target != @shot.id}
          type="button"
          phx-click="pick_image"
          phx-value-id={@shot.id}
          class="flex aspect-video w-32 items-center justify-center rounded border border-dashed border-base-300 text-[11px] text-base-content/50 transition hover:border-base-content/40 hover:text-base-content print:hidden"
          title="Add a storyboard frame (frames up to 3 MB reach linked installations too)"
        >
          <.icon name="hero-photo" class="mr-1 size-3.5" /> Frame
        </button>
        <div :if={@shot.image && @editable} class="mt-0.5 flex gap-2 text-[10px] print:hidden">
          <button
            type="button"
            phx-click="pick_image"
            phx-value-id={@shot.id}
            class="text-base-content/50 hover:text-base-content"
          >
            Replace
          </button>
          <button
            type="button"
            phx-click="remove_image"
            phx-value-id={@shot.id}
            class="text-base-content/50 hover:text-error"
          >
            Remove
          </button>
        </div>
        <form
          :if={@image_target == @shot.id}
          id={"shot-image-form-#{@shot.id}"}
          phx-change="validate_image"
          phx-submit="validate_image"
          class="mt-1 space-y-1 print:hidden"
        >
          <.live_file_input upload={@uploads.image} class="w-full text-[11px]" />
          <p :for={entry <- @uploads.image.entries} class="text-[10px] text-base-content/60">
            {entry.progress}%
            <span :for={err <- upload_errors(@uploads.image, entry)} class="text-error">
              {upload_error(err)}
            </span>
          </p>
          <p :for={err <- upload_errors(@uploads.image)} class="text-[10px] text-error">
            {upload_error(err)}
          </p>
          <button
            type="button"
            phx-click="cancel_image"
            class="text-[10px] text-base-content/50 hover:text-base-content"
          >
            Cancel
          </button>
        </form>
      </div>

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
