defmodule MoorlandWeb.ScriptLive.Media do
  @moduledoc """
  The media library: a production's reference files (location photos,
  costume and prop references, lookbooks, temp tracks) gathered beside the
  script, and mood boards, which are named selections of them. Files are
  dropped in here; anyone who may comment may add them, and they reach
  every installation the script is shared with (up to 3 MB each).
  """
  use MoorlandWeb, :live_view

  alias Moorland.Scripts
  alias Moorland.Scripts.{Activity, MediaItem}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {script, role} = Scripts.get_script!(socket.assigns.current_scope, id)
    if connected?(socket), do: Scripts.subscribe(script.id)

    {:ok,
     socket
     |> assign(
       script: script,
       role: role,
       page_title: "Media · #{script.title}",
       board: nil,
       editing: nil
     )
     |> allow_upload(:files,
       # Extensions MIME knows, plus any sound (.m4a, .ogg); add_media checks the rest.
       accept:
         Enum.filter(
           MediaItem.extensions(),
           &(MIME.from_path("x" <> &1) != "application/octet-stream")
         ) ++
           ["audio/*"],
       max_entries: 10,
       max_file_size: Scripts.max_media_size(),
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> reload()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    board =
      case params["board"] do
        name when is_binary(name) and name != "" -> name
        _ -> nil
      end

    {:noreply, socket |> assign(:board, board) |> reload()}
  end

  defp reload(socket) do
    %{script: script, board: board} = socket.assigns
    all = Scripts.list_media(script)
    dir = Moorland.Storage.media_dir(script.id)

    items =
      all
      |> Enum.filter(&(is_nil(board) or &1.board == board))
      |> Enum.map(&Map.put(&1, :here?, File.exists?(Path.join(dir, &1.file || ""))))

    counts = all |> Enum.reject(&(&1.board == "")) |> Enum.frequencies_by(& &1.board)
    counts = if board, do: Map.put_new(counts, board, 0), else: counts
    boards = Enum.sort_by(counts, fn {name, _} -> String.downcase(name) end)

    assign(socket, items: items, boards: boards, total: length(all))
  end

  ## Events

  @impl true
  def handle_event("validate_files", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :files, ref)}

  def handle_event("edit", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {id, ""} -> {:noreply, assign(socket, :editing, id)}
      _ -> {:noreply, socket}
    end
  end

  # A board exists once something is pinned to it; until then it is just
  # where new uploads land.
  def handle_event("new_board", %{"name" => name}, socket) do
    case String.trim(name) do
      "" ->
        {:noreply, socket}

      name ->
        {:noreply,
         push_patch(socket,
           to:
             ~p"/scripts/#{socket.assigns.script.id}/media?#{[board: String.slice(name, 0, 80)]}"
         )}
    end
  end

  def handle_event("done_editing", _params, socket), do: {:noreply, assign(socket, :editing, nil)}

  def handle_event("update_item", %{"item_id" => id} = params, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    Scripts.update_media(scope, script, id, Map.take(params, ~w(title caption board)))
    |> respond(socket)
  end

  def handle_event("pin", %{"id" => id, "board" => board}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.update_media(scope, script, id, %{board: board}) |> respond(socket)
  end

  def handle_event("delete_item", %{"id" => id}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.delete_media(scope, script, id) |> respond(assign(socket, :editing, nil))
  end

  # Each file joins the library the moment it finishes uploading, pinned
  # to the board on show.
  defp handle_progress(:files, entry, socket) do
    if entry.done? do
      %{current_scope: scope, script: script, board: board} = socket.assigns

      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Scripts.add_media(scope, script, path, entry.client_name, %{board: board || ""})}
        end)

      respond(result, socket)
    else
      {:noreply, socket}
    end
  end

  defp respond({:error, :not_allowed}, socket),
    do: {:noreply, put_flash(socket, :error, "That is someone else's to change.")}

  defp respond({:error, :unsupported}, socket),
    do: {:noreply, put_flash(socket, :error, "Pictures, PDFs, sound and video only.")}

  defp respond({:error, :too_large}, socket),
    do: {:noreply, put_flash(socket, :error, "Files up to 50 MB.")}

  defp respond({:error, %Ecto.Changeset{}}, socket),
    do: {:noreply, put_flash(socket, :error, "That couldn't be saved.")}

  defp respond(_result, socket), do: {:noreply, reload(socket)}

  @impl true
  def handle_info({:media_changed, _id}, socket), do: {:noreply, reload(socket)}

  def handle_info({:script_updated, _id}, socket) do
    {script, role} = Scripts.get_script!(socket.assigns.current_scope, socket.assigns.script.id)
    {:noreply, socket |> assign(script: script, role: role) |> reload()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Render

  defp can_change?(item, role, user_id), do: item.author_id == user_id or Scripts.can_edit?(role)

  defp upload_error(:too_large), do: "Files up to 50 MB."
  defp upload_error(:not_accepted), do: "Pictures, PDFs, sound and video only."
  defp upload_error(:too_many_files), do: "Ten files at a time."
  defp upload_error(_), do: "That upload failed."

  defp file_url(script_id, item, download \\ false) do
    query = if download, do: "?download=1", else: "?v=#{item.file}"
    "/scripts/#{script_id}/media/#{item.id}/file#{query}"
  end

  defp human_size(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp human_size(bytes) when bytes >= 1_000, do: "#{div(bytes, 1_000)} KB"
  defp human_size(bytes), do: "#{bytes} B"

  defp kind_icon("pdf"), do: "hero-document-text"
  defp kind_icon("audio"), do: "hero-musical-note"
  defp kind_icon("video"), do: "hero-film"
  defp kind_icon(_), do: "hero-paper-clip"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} section={:scripts} wide>
      <div class="py-2">
        <MoorlandWeb.ProductionComponents.production_header
          script={@script}
          current={:media}
          title={if @board, do: @board, else: "Media"}
        >
          <:subtitle>
            {if @board, do: "Mood board · "}{length(@items)} {if length(@items) == 1,
              do: "file",
              else: "files"}
          </:subtitle>
        </MoorlandWeb.ProductionComponents.production_header>

        <nav id="media-boards" class="mt-5 flex flex-wrap items-center gap-1.5 text-sm">
          <.link
            patch={~p"/scripts/#{@script.id}/media"}
            class={[
              "rounded-full border px-3 py-1 transition",
              if(is_nil(@board),
                do: "border-neutral bg-neutral text-neutral-content",
                else: "border-base-300 hover:border-base-content/40"
              )
            ]}
          >
            Everything <span class="opacity-60">{@total}</span>
          </.link>
          <.link
            :for={{name, count} <- @boards}
            id={"board-#{Base.url_encode64(name, padding: false)}"}
            patch={~p"/scripts/#{@script.id}/media?#{[board: name]}"}
            class={[
              "rounded-full border px-3 py-1 transition",
              if(@board == name,
                do: "border-neutral bg-neutral text-neutral-content",
                else: "border-base-300 hover:border-base-content/40"
              )
            ]}
          >
            <.icon name="hero-squares-2x2" class="mr-0.5 size-3.5 opacity-60" />{name}
            <span class="opacity-60">{count}</span>
          </.link>
          <form
            :if={Scripts.can_comment?(@role)}
            id="new-board-form"
            phx-submit="new_board"
            class="flex items-center"
          >
            <input
              type="text"
              name="name"
              maxlength="80"
              autocomplete="off"
              placeholder="New mood board…"
              class="input input-bordered input-sm h-[30px] w-44 rounded-full"
            />
          </form>
        </nav>

        <form
          :if={Scripts.can_comment?(@role)}
          id="media-upload"
          phx-change="validate_files"
          phx-submit="validate_files"
          phx-drop-target={@uploads.files.ref}
          class="mt-4 rounded-xl border-2 border-dashed border-base-300 px-4 py-6 text-center transition hover:border-base-content/30 [&.phx-drop-target-active]:border-primary [&.phx-drop-target-active]:bg-primary/5"
        >
          <.icon name="hero-arrow-up-tray" class="size-5 text-base-content/40" />
          <p class="mt-1 text-sm">
            Drop pictures, PDFs, sound or video here, or
            <label class="cursor-pointer font-medium underline">
              choose files <.live_file_input upload={@uploads.files} class="sr-only" />
            </label>
          </p>
          <p class="mt-1 text-[11px] text-base-content/50">
            Up to 50 MB each{if @board, do: ", pinned to #{@board}", else: ""}. Files up to 3 MB reach linked installations; bigger ones stay on this computer.
          </p>
          <div :if={@uploads.files.entries != []} class="mx-auto mt-3 max-w-md space-y-1 text-left">
            <div
              :for={entry <- @uploads.files.entries}
              class="flex items-center gap-2 text-xs"
            >
              <span class="min-w-0 flex-1 truncate">{entry.client_name}</span>
              <progress class="progress w-24" value={entry.progress} max="100"></progress>
              <span :for={err <- upload_errors(@uploads.files, entry)} class="text-error">
                {upload_error(err)}
              </span>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="text-base-content/40 hover:text-error"
                aria-label="Cancel"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </div>
          </div>
          <p :for={err <- upload_errors(@uploads.files)} class="mt-2 text-xs text-error">
            {upload_error(err)}
          </p>
        </form>

        <div
          :if={@items == []}
          id="media-empty"
          class="mt-8 rounded-lg border border-dashed border-base-300 px-6 py-12 text-center text-sm text-base-content/50"
        >
          {if @board,
            do: "Nothing on this board yet. Drop files above, or pin them from Everything.",
            else: "Reference pictures, lookbooks, temp tracks: everything the production should see."}
        </div>

        <div
          id="media-items"
          class={[
            "mt-6 gap-4",
            if(@board,
              do: "columns-1 sm:columns-2 lg:columns-3",
              else: "grid sm:grid-cols-2 lg:grid-cols-4"
            )
          ]}
        >
          <.item
            :for={item <- @items}
            item={item}
            script_id={@script.id}
            board={@board}
            boards={@boards}
            editing={@editing == item.id}
            editable={can_change?(item, @role, @current_scope.user.id)}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :item, :map, required: true
  attr :script_id, :integer, required: true
  attr :board, :any, required: true
  attr :boards, :list, required: true
  attr :editing, :boolean, required: true
  attr :editable, :boolean, required: true

  defp item(assigns) do
    assigns = assign(assigns, :kind, MediaItem.kind(assigns.item))

    ~H"""
    <article
      id={"media-#{@item.id}"}
      class="group mb-4 break-inside-avoid overflow-hidden rounded-lg border border-base-300 bg-base-100 transition hover:shadow-md"
    >
      <%= cond do %>
        <% !@item.here? -> %>
          <div class="flex aspect-video flex-col items-center justify-center gap-1 bg-base-200 px-4 text-center text-xs text-base-content/50">
            <.icon name={kind_icon(@kind)} class="size-6" />
            {if @item.size > Activity.max_synced_file(),
              do: "Too big to travel; it stays with #{Activity.handle(@item)}.",
              else: "On its way from #{Activity.handle(@item)}…"}
          </div>
        <% @kind == "image" -> %>
          <a href={file_url(@script_id, @item)} target="_blank" rel="noopener" class="block">
            <img
              src={file_url(@script_id, @item)}
              alt={MediaItem.label(@item)}
              loading="lazy"
              class={[
                "w-full bg-base-200 transition group-hover:opacity-95",
                if(@board, do: "h-auto", else: "aspect-[4/3] object-cover")
              ]}
            />
          </a>
        <% @kind == "audio" -> %>
          <div class="flex flex-col items-center gap-2 bg-base-200 px-3 py-6">
            <.icon name="hero-musical-note" class="size-6 text-base-content/40" />
            <audio controls preload="none" src={file_url(@script_id, @item)} class="w-full"></audio>
          </div>
        <% @kind == "video" -> %>
          <video
            controls
            preload="metadata"
            src={file_url(@script_id, @item)}
            class="aspect-video w-full bg-black"
          ></video>
        <% true -> %>
          <a
            href={file_url(@script_id, @item)}
            target="_blank"
            rel="noopener"
            class="flex aspect-[4/3] flex-col items-center justify-center gap-2 bg-base-200 text-base-content/50 transition hover:text-base-content"
          >
            <.icon name={kind_icon(@kind)} class="size-8" />
            <span class="text-xs uppercase tracking-wide">{@kind}</span>
          </a>
      <% end %>

      <div class="space-y-1 p-3">
        <%= if @editing do %>
          <form
            id={"media-form-#{@item.id}"}
            phx-change="update_item"
            phx-submit="done_editing"
            class="space-y-1.5"
          >
            <input type="hidden" name="item_id" value={@item.id} />
            <input
              type="text"
              name="title"
              value={@item.title}
              maxlength="200"
              placeholder="Title"
              phx-debounce="500"
              class="input input-bordered input-xs w-full"
            />
            <textarea
              name="caption"
              rows="2"
              maxlength="2000"
              placeholder="What it's for: the look, the place, the cue"
              phx-debounce="500"
              class="textarea textarea-bordered textarea-xs w-full"
            >{@item.caption}</textarea>
            <input
              type="text"
              name="board"
              value={@item.board}
              maxlength="80"
              list={"boards-#{@item.id}"}
              placeholder="Mood board (none)"
              phx-debounce="500"
              class="input input-bordered input-xs w-full"
            />
            <datalist id={"boards-#{@item.id}"}>
              <option :for={{name, _} <- @boards} value={name}></option>
            </datalist>
            <div class="flex items-center justify-between pt-1">
              <button
                type="button"
                phx-click="delete_item"
                phx-value-id={@item.id}
                data-confirm="Remove this file from the library, here and for everyone it reaches?"
                class="text-xs text-base-content/50 hover:text-error"
              >
                Remove
              </button>
              <button type="submit" class="btn btn-neutral btn-xs">Done</button>
            </div>
          </form>
        <% else %>
          <div class="flex items-start gap-2">
            <h3 class="min-w-0 flex-1 truncate text-sm font-medium" title={@item.filename}>
              {MediaItem.label(@item)}
            </h3>
            <button
              :if={@editable}
              type="button"
              phx-click="edit"
              phx-value-id={@item.id}
              class="rounded p-0.5 text-base-content/40 transition hover:text-base-content focus:opacity-100 sm:opacity-0 sm:group-hover:opacity-100"
              title="Edit title, caption and board"
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </button>
          </div>
          <p
            :if={@item.caption != ""}
            phx-no-format
            class="whitespace-pre-line text-xs text-base-content/70"
          >{@item.caption}</p>
          <div class="flex flex-wrap items-center gap-x-2 gap-y-1 pt-0.5 text-[11px] text-base-content/50">
            <.link
              :if={@item.board != "" && is_nil(@board)}
              patch={~p"/scripts/#{@script_id}/media?#{[board: @item.board]}"}
              class="rounded bg-base-200 px-1.5 py-0.5 hover:text-base-content"
            >
              {@item.board}
            </.link>
            <span>{human_size(@item.size)}</span>
            <span>· {Activity.handle(@item)}</span>
            <a
              :if={@item.here?}
              href={file_url(@script_id, @item, true)}
              class="ml-auto hover:text-base-content"
              title="Download"
            >
              <.icon name="hero-arrow-down-tray" class="size-3.5" />
            </a>
          </div>
          <div
            :if={@editable && @item.board == "" && @boards != [] && is_nil(@board)}
            class="flex flex-wrap gap-1 pt-1 transition sm:opacity-0 sm:group-hover:opacity-100 sm:focus-within:opacity-100"
          >
            <button
              :for={{name, _} <- @boards}
              type="button"
              phx-click="pin"
              phx-value-id={@item.id}
              phx-value-board={name}
              class="rounded border border-base-300 px-1.5 py-0.5 text-[10px] text-base-content/60 hover:border-base-content/40 hover:text-base-content"
              title={"Pin to #{name}"}
            >
              + {name}
            </button>
          </div>
        <% end %>
      </div>
    </article>
    """
  end
end
