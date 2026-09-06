defmodule MoorlandWeb.ScriptLive.Index do
  use MoorlandWeb, :live_view

  alias Moorland.Scripts

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Moorland.PubSub, "user:#{socket.assigns.current_scope.user.id}")
    end

    {:ok, socket |> assign(search_q: "", results: nil) |> refresh(), temporary_assigns: []}
  end

  @impl true
  def handle_info(:notifications_changed, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("create", %{"title" => title}, socket) do
    title = if String.trim(title) == "", do: "Untitled", else: String.trim(title)

    case Scripts.create_script(socket.assigns.current_scope, %{title: title}) do
      {:ok, script} ->
        {:noreply, push_navigate(socket, to: ~p"/scripts/#{script.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create the script.")}
    end
  end

  def handle_event("import_script", %{"title" => title, "content" => content}, socket)
      when is_binary(title) and is_binary(content) do
    if byte_size(content) > 2_000_000 do
      {:noreply, put_flash(socket, :error, "That file is too large (2 MB max).")}
    else
      title = title |> String.trim() |> String.slice(0, 200)
      title = if title == "", do: "Imported script", else: title

      case Scripts.create_script(socket.assigns.current_scope, %{title: title, content: content}) do
        {:ok, script} ->
          {:noreply, push_navigate(socket, to: ~p"/scripts/#{script.id}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not import that file.")}
      end
    end
  end

  def handle_event("import_failed", %{"reason" => reason}, socket) do
    {:noreply, put_flash(socket, :error, String.slice(to_string(reason), 0, 200))}
  end

  def handle_event("search", %{"q" => q}, socket) do
    results =
      if String.trim(q) == "",
        do: nil,
        else: Scripts.search(socket.assigns.current_scope, q)

    {:noreply, assign(socket, search_q: q, results: results)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    {script, _role} = Scripts.get_script!(scope, id)

    case Scripts.delete_script(scope, script) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Script deleted.") |> refresh()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Only the owner can delete a script.")}
    end
  end

  defp refresh(socket) do
    socket
    |> assign(:scripts, Scripts.list_scripts(socket.assigns.current_scope))
    |> assign(:peer_names, Moorland.Peers.names_by_key())
    |> assign(:update, Moorland.Updates.banner_info())
    |> assign(:unread, Scripts.unread_notifications(socket.assigns.current_scope))
  end

  attr :script, :map, required: true
  attr :mine, :boolean, required: true
  attr :unread, :integer, default: 0

  defp script_card(assigns) do
    ~H"""
    <div class="group relative">
      <.link
        navigate={~p"/scripts/#{@script.id}"}
        class="block rounded-lg border border-base-300 bg-base-100 px-5 py-4 transition hover:border-neutral hover:shadow-sm"
      >
        <div class="flex items-center gap-2 pr-8">
          <span class="min-w-0 truncate font-medium text-base-content">{@script.title}</span>
          <span
            :if={@unread > 0}
            class="shrink-0 rounded-full bg-error px-1.5 text-[10px] font-semibold text-error-content"
            title={"#{@unread} unread comments"}
          >
            {@unread}
          </span>
        </div>
        <div class="mt-1 text-xs text-base-content/50">
          <span :if={!@mine}>by {@script.owner.email} · </span>
          updated {Calendar.strftime(@script.updated_at, "%b %d, %Y at %H:%M")}
        </div>
      </.link>
      <button
        :if={@mine}
        phx-click="delete"
        phx-value-id={@script.id}
        data-confirm={"Delete \"#{@script.title}\"? This removes its versions, comments and notes."}
        class="absolute right-3 top-3 hidden rounded p-1 text-base-content/40 hover:bg-base-200 hover:text-error group-hover:block"
        title="Delete script"
      >
        <.icon name="hero-trash" class="size-4" />
      </button>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl py-10">
        <div class="flex items-end justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Scripts</h1>
            <p class="mt-1 text-sm text-base-content/60">
              Everything you own or collaborate on.
            </p>
          </div>
          <div class="flex gap-1">
            <.link navigate={~p"/contacts"} class="btn btn-ghost btn-sm" title="Cast & crew rolodex">
              <.icon name="hero-identification" class="size-4" /> Contacts
            </.link>
            <.link navigate={~p"/peers"} class="btn btn-ghost btn-sm" title="Peer-to-peer collaboration">
              <.icon name="hero-signal" class="size-4" /> Peers
            </.link>
          </div>
        </div>

        <div
          :if={@update}
          id="update-banner"
          phx-hook="UpdateBanner"
          phx-update="ignore"
          data-latest={@update.latest.tag}
          class="mt-6 rounded-lg border border-base-300 bg-base-200/40 px-4 py-3 text-sm"
        >
          <div class="flex items-center gap-2">
            <.icon name="hero-arrow-up-circle" class="size-4 shrink-0 text-base-content/60" />
            <span class="min-w-0 truncate">
              <span class="font-medium">Moorland {@update.latest.tag}</span>
              is available — you're on {@update.current}.
            </span>
            <button type="button" data-toggle-versions class="btn btn-ghost btn-xs ml-auto shrink-0">
              Versions
            </button>
            <a
              href={@update.latest.url}
              target="_blank"
              rel="noopener"
              class="btn btn-neutral btn-xs shrink-0"
            >
              Get {@update.latest.tag}
            </a>
            <button
              type="button"
              data-dismiss
              class="shrink-0 rounded p-1 text-base-content/40 hover:text-base-content"
              title="Dismiss this version"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <div data-versions hidden class="mt-3 space-y-1 border-t border-base-300 pt-2">
            <div
              :for={release <- @update.releases}
              class={[
                "flex items-center gap-2 rounded px-2 py-1 text-xs",
                release.latest && "bg-base-200 font-medium"
              ]}
            >
              <span>{release.tag}</span>
              <span
                :if={release.latest}
                class="rounded-full bg-neutral px-1.5 text-[10px] text-neutral-content"
              >
                latest
              </span>
              <span :if={release.current} class="text-base-content/50">installed</span>
              <span :if={release.prerelease} class="text-[10px] text-warning">pre-release</span>
              <span class="ml-auto text-base-content/40">{release.date}</span>
              <a href={release.url} target="_blank" rel="noopener" class="underline">view</a>
            </div>
            <p class="pt-1 text-[11px] text-base-content/50">
              Pick any version above — until packaged builds land, updating means pulling that
              release and restarting Moorland.
            </p>
          </div>
        </div>

        <form id="search-form" phx-change="search" phx-submit="search" class="mt-6">
          <input
            type="search"
            name="q"
            value={@search_q}
            placeholder="Search scripts, comments and notes…"
            autocomplete="off"
            phx-debounce="300"
            class="input input-bordered input-sm w-full"
          />
        </form>

        <div :if={@results} class="mt-3 divide-y divide-base-200 rounded-lg border border-base-300">
          <.link
            :for={hit <- @results}
            navigate={~p"/scripts/#{hit.script_id}"}
            class="flex items-baseline gap-2 px-4 py-2.5 hover:bg-base-200"
          >
            <span class="shrink-0 rounded bg-base-200 px-1.5 text-[10px] uppercase text-base-content/50">
              {hit.kind}
            </span>
            <span class="shrink-0 text-sm font-medium">{hit.title}</span>
            <span class="min-w-0 truncate text-xs text-base-content/50">{hit.snippet}</span>
          </.link>
          <p :if={@results == []} class="px-4 py-4 text-center text-sm text-base-content/40">
            No matches.
          </p>
        </div>

        <form id="create-script-form" phx-submit="create" class="mt-6 flex gap-2">
          <input
            type="text"
            name="title"
            placeholder="New script title…"
            autocomplete="off"
            class="input input-bordered flex-1"
          />
          <button type="submit" class="btn btn-neutral">
            <.icon name="hero-plus" class="size-4" /> New script
          </button>
          <label
            id="script-importer"
            phx-hook="ScriptImporter"
            phx-update="ignore"
            class="btn btn-ghost"
            title="Import a .fountain, .txt or Final Draft .fdx file"
          >
            <.icon name="hero-arrow-up-tray" class="size-4" /> Import
            <input type="file" accept=".fountain,.txt,.fdx" class="hidden" />
          </label>
        </form>

        <% mirrors = Enum.filter(@scripts, & &1.origin_public_key) %>
        <% mine =
          Enum.filter(@scripts, &(&1.owner_id == @current_scope.user.id and !&1.origin_public_key)) %>
        <% shared = Enum.reject(@scripts, &(&1.owner_id == @current_scope.user.id)) %>

        <div class="mt-8 space-y-2">
          <.script_card
            :for={script <- mine}
            script={script}
            mine={true}
            unread={Map.get(@unread, script.id, 0)}
          />
        </div>

        <div :if={shared != []} class="mt-10">
          <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Shared with you
          </h2>
          <div class="mt-3 space-y-2">
            <.script_card
              :for={script <- shared}
              script={script}
              mine={false}
              unread={Map.get(@unread, script.id, 0)}
            />
          </div>
        </div>

        <div :if={mirrors != []} class="mt-10">
          <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            From peers
          </h2>
          <div class="mt-3 space-y-2">
            <div :for={script <- mirrors} class="group relative">
              <.link
                navigate={~p"/scripts/#{script.id}"}
                class="block rounded-lg border border-base-300 bg-base-100 px-5 py-4 transition hover:border-neutral hover:shadow-sm"
              >
                <div class="font-medium text-base-content truncate pr-8">{script.title}</div>
                <div class="mt-1 text-xs text-base-content/50">
                  via {Map.get(@peer_names, script.origin_public_key, "unknown peer")}
                  · {script.origin_role || "editor"}
                  · updated {Calendar.strftime(script.updated_at, "%b %d, %Y at %H:%M")}
                </div>
              </.link>
              <button
                phx-click="delete"
                phx-value-id={script.id}
                data-confirm={"Remove your synced copy of \"#{script.title}\"? The peer's original is untouched."}
                class="absolute right-3 top-3 hidden rounded p-1 text-base-content/40 hover:bg-base-200 hover:text-error group-hover:block"
                title="Remove synced copy"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </div>
        </div>

        <div :if={@scripts == []} class="mt-16 text-center text-base-content/50">
          <.icon name="hero-document-text" class="mx-auto size-10 opacity-40" />
          <p class="mt-3 text-sm">No scripts yet. Give one a title above to get started.</p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
