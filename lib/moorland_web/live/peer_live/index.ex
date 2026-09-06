defmodule MoorlandWeb.PeerLive.Index do
  use MoorlandWeb, :live_view

  alias Moorland.Peers
  alias Moorland.Peers.Crypto

  @impl true
  def mount(_params, _session, socket) do
    {:ok, refresh(socket)}
  end

  defp refresh(socket) do
    identity = Peers.identity()

    assign(socket,
      page_title: "Peers",
      identity: identity,
      code: Peers.peer_code(),
      short_id: Crypto.fingerprint(identity.public_key),
      peers: Peers.list_peers(socket.assigns.current_scope),
      nearby: nearby_not_added(socket),
      data_dir: Moorland.Storage.data_dir(),
      mirror_dir: Moorland.Storage.mirror_dir()
    )
  end

  defp nearby_not_added(socket) do
    known =
      socket.assigns.current_scope
      |> Peers.list_peers()
      |> MapSet.new(& &1.public_key)

    Moorland.Peers.Discovery.nearby()
    |> Enum.reject(&MapSet.member?(known, &1.public_key))
  rescue
    _ -> []
  end

  @impl true
  def handle_event("update_identity", %{"name" => name, "host" => host, "port" => port}, socket) do
    case Peers.update_identity(%{name: name, host: host, port: port}) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Address updated — share your new code.") |> refresh()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update the address.")}
    end
  end

  def handle_event("add_peer", %{"code" => code, "name" => name}, socket) do
    case Peers.add_peer(socket.assigns.current_scope, code, name) do
      {:ok, _} ->
        Moorland.Peers.Sync.sync_now()
        {:noreply, socket |> put_flash(:info, "Peer added. Syncing…") |> refresh()}

      {:error, :invalid_code} ->
        {:noreply, put_flash(socket, :error, "That doesn't look like a peer code.")}

      {:error, :own_code} ->
        {:noreply, put_flash(socket, :error, "That's this installation's own code.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "That peer is already added.")}
    end
  end

  def handle_event("remove_peer", %{"id" => id}, socket) do
    Peers.remove_peer(socket.assigns.current_scope, id)
    {:noreply, refresh(socket)}
  end

  def handle_event("sync_now", _params, socket) do
    Moorland.Peers.Sync.sync_now()
    {:noreply, put_flash(socket, :info, "Sync requested.")}
  end

  def handle_event("add_nearby", %{"key" => key64}, socket) do
    with {:ok, public_key} <- Moorland.Peers.Crypto.decode_key(key64),
         entry when entry != nil <-
           Enum.find(Moorland.Peers.Discovery.nearby(), &(&1.public_key == public_key)),
         {:ok, _} <- Peers.add_discovered_peer(socket.assigns.current_scope, entry) do
      Moorland.Peers.Sync.sync_now()
      {:noreply, socket |> put_flash(:info, "#{entry.name} added. Syncing…") |> refresh()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Couldn't add that installation.")}
    end
  end

  def handle_event("check_updates", _params, socket) do
    message =
      case Moorland.Updates.check_now() do
        {:ok, _count} ->
          case Moorland.Updates.banner_info() do
            nil ->
              "You're on the latest version (#{Moorland.Updates.current_version()})."

            %{latest: latest} ->
              "Moorland #{latest.tag} is available — see the banner on your Scripts page."
          end

        {:error, :not_configured} ->
          "Update checks are off. Set :update_repo in config/config.exs to your GitHub repo."

        {:error, :repo_not_found} ->
          "The configured update repo wasn't found on GitHub."

        {:error, _} ->
          "Couldn't reach GitHub to check for updates."
      end

    {:noreply, put_flash(socket, :info, message)}
  end

  def handle_event("relocate", %{"dir" => dir}, socket) do
    case Moorland.Storage.relocate(dir) do
      {:ok, :copied, new_dir} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Data copied to #{new_dir}. Restart Moorland to start using it."
         )}

      {:ok, :adopted, new_dir} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Existing Moorland data found at #{new_dir} and adopted. Restart to switch."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not use that folder: #{reason}")}
    end
  end

  defp seen_label(nil), do: "never reached"

  defp seen_label(at) do
    seconds = DateTime.diff(DateTime.utc_now(), at)

    cond do
      seconds < 30 -> "online"
      seconds < 3600 -> "seen #{div(seconds, 60)}m ago"
      seconds < 86_400 -> "seen #{div(seconds, 3600)}h ago"
      true -> "seen #{Calendar.strftime(at, "%b %d")}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl py-10">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/scripts"} class="rounded p-1.5 text-base-content/60 hover:bg-base-200">
            <.icon name="hero-chevron-left" class="size-4" />
          </.link>
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Peers</h1>
            <p class="mt-1 text-sm text-base-content/60">
              Direct, serverless collaboration between Moorland installations.
            </p>
          </div>
        </div>

        <div class="mt-8 rounded-lg border border-base-300 p-5">
          <div class="flex items-center justify-between">
            <h2 class="text-sm font-semibold">This installation</h2>
            <span class="font-mono text-[11px] text-base-content/50">
              v{Moorland.Updates.current_version()} · id {@short_id}
            </span>
          </div>

          <div class="mt-3 flex gap-2">
            <input
              id="peer-code"
              type="text"
              readonly
              value={@code}
              class="input input-bordered input-sm flex-1 font-mono text-xs"
            />
            <button
              type="button"
              class="btn btn-neutral btn-sm"
              onclick="navigator.clipboard.writeText(document.getElementById('peer-code').value); this.textContent='Copied'; setTimeout(() => this.textContent = 'Copy', 1500)"
            >
              Copy
            </button>
          </div>
          <p class="mt-2 text-[11px] text-base-content/50">
            Give this code to people you write with. Collaboration needs both sides to add each
            other, and works wherever this address is reachable — a LAN, a VPN like Tailscale, a
            forwarded port, or the open internet: everything between installs is end-to-end encrypted.
          </p>

          <form
            id="identity-form"
            phx-submit="update_identity"
            class="mt-4 flex flex-wrap items-end gap-2"
          >
            <label class="flex-1 min-w-32">
              <span class="text-[11px] text-base-content/50">Display name</span>
              <input
                type="text"
                name="name"
                value={@identity.name}
                class="input input-bordered input-sm w-full"
              />
            </label>
            <label class="flex-1 min-w-32">
              <span class="text-[11px] text-base-content/50">Reachable host</span>
              <input
                type="text"
                name="host"
                value={@identity.host}
                class="input input-bordered input-sm w-full font-mono"
              />
            </label>
            <label class="w-24">
              <span class="text-[11px] text-base-content/50">Port</span>
              <input
                type="number"
                name="port"
                value={@identity.port}
                class="input input-bordered input-sm w-full"
              />
            </label>
            <button type="submit" class="btn btn-ghost btn-sm">Save</button>
            <button type="button" phx-click="check_updates" class="btn btn-ghost btn-sm">
              <.icon name="hero-arrow-up-circle" class="size-4" /> Check for updates
            </button>
          </form>
        </div>

        <div class="mt-6 rounded-lg border border-base-300 p-5">
          <h2 class="text-sm font-semibold">Storage</h2>
          <p class="mt-1 text-[11px] text-base-content/50">
            Your writing lives in this folder — the database plus a plain-text
            <span class="font-mono">.fountain</span>
            copy of every script, readable in any text editor without Moorland. Point it at an
            external drive or a Google Drive / iCloud / Dropbox folder for automatic backup.
            Run Moorland against a synced folder from one machine at a time.
          </p>

          <div class="mt-3 space-y-1 text-xs">
            <div class="flex gap-2">
              <span class="w-20 shrink-0 text-base-content/50">Data folder</span>
              <span class="min-w-0 truncate font-mono">{@data_dir}</span>
            </div>
            <div class="flex gap-2">
              <span class="w-20 shrink-0 text-base-content/50">Plain text</span>
              <span class="min-w-0 truncate font-mono">{@mirror_dir}</span>
            </div>
          </div>

          <form id="relocate-form" phx-submit="relocate" class="mt-3 flex gap-2">
            <input
              type="text"
              name="dir"
              required
              placeholder="D:\Writing\Moorland or C:\Users\you\Google Drive\Moorland"
              autocomplete="off"
              class="input input-bordered input-sm flex-1 font-mono text-xs"
            />
            <button
              type="submit"
              class="btn btn-neutral btn-sm"
              data-confirm="Move Moorland's data folder? Your current data is copied there (or an existing Moorland folder is adopted), and the change applies after a restart."
            >
              Move
            </button>
          </form>
        </div>

        <div class="mt-6 rounded-lg border border-base-300 p-5">
          <h2 class="text-sm font-semibold">Add a peer</h2>
          <form id="add-peer-form" phx-submit="add_peer" class="mt-3 space-y-2">
            <input
              type="text"
              name="code"
              required
              placeholder="moor:…@host:port"
              autocomplete="off"
              class="input input-bordered input-sm w-full font-mono text-xs"
            />
            <div class="flex gap-2">
              <input
                type="text"
                name="name"
                required
                placeholder="Their name"
                autocomplete="off"
                class="input input-bordered input-sm flex-1"
              />
              <button type="submit" class="btn btn-neutral btn-sm">Add peer</button>
            </div>
          </form>
        </div>

        <div :if={@nearby != []} class="mt-6 rounded-lg border border-base-300 p-5">
          <h2 class="text-sm font-semibold">Nearby on this network</h2>
          <p class="mt-0.5 text-[11px] text-base-content/50">
            Moorland installations found automatically on your LAN — no code pasting needed.
          </p>
          <div class="mt-2 space-y-1.5">
            <div :for={found <- @nearby} class="flex items-center gap-3">
              <div class="min-w-0 flex-1">
                <span class="text-sm">{found.name}</span>
                <span class="ml-2 font-mono text-[10px] text-base-content/40">
                  {found.host}:{found.port}
                </span>
              </div>
              <button
                phx-click="add_nearby"
                phx-value-key={Moorland.Peers.Crypto.encode_key(found.public_key)}
                class="btn btn-neutral btn-xs"
              >
                Add
              </button>
            </div>
          </div>
        </div>

        <div class="mt-6">
          <div class="flex items-center justify-between">
            <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
              Known peers
            </h2>
            <button :if={@peers != []} phx-click="sync_now" class="btn btn-ghost btn-xs">
              <.icon name="hero-arrow-path" class="size-3.5" /> Sync now
            </button>
          </div>

          <div class="mt-3 divide-y divide-base-200 rounded-lg border border-base-300">
            <div :for={peer <- @peers} class="flex items-center gap-3 px-4 py-3">
              <div class="min-w-0 flex-1">
                <div class="flex items-baseline gap-2">
                  <span class="truncate text-sm font-medium">{peer.name}</span>
                  <span class="font-mono text-[10px] text-base-content/40">
                    {Crypto.fingerprint(peer.public_key)}
                  </span>
                </div>
                <div class="mt-0.5 text-[11px] text-base-content/50">
                  <span class="font-mono">{peer.host}:{peer.port}</span>
                  · {seen_label(peer.last_seen_at)}
                  <span :if={peer.last_error} class="text-error"> · {peer.last_error}</span>
                </div>
              </div>
              <button
                phx-click="remove_peer"
                phx-value-id={peer.id}
                data-confirm={"Remove #{peer.name}? Their mirrored scripts stay on this machine but stop syncing."}
                class="rounded p-1 text-base-content/40 hover:text-error"
                title="Remove peer"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <p :if={@peers == []} class="px-4 py-8 text-center text-sm text-base-content/40">
              No peers yet. Swap codes with someone to start a writing circle.
            </p>
          </div>
          <p class="mt-2 text-[11px] text-base-content/50">
            Share individual scripts with a peer from the editor's Share panel. What they share
            with you appears on your Scripts page under “From peers”.
          </p>
        </div>

        <div class="mt-6 flex items-center justify-between rounded-lg border border-base-300 px-5 py-4">
          <div>
            <h2 class="text-sm font-semibold">About Moorland</h2>
            <p class="mt-0.5 text-[11px] text-base-content/50">
              v{Moorland.Updates.current_version()} — free, distributed screenwriting.
              Your scripts stay yours: open Fountain files, no central server.
            </p>
          </div>
          <a
            :if={Application.get_env(:moorland, :support_url)}
            href={Application.get_env(:moorland, :support_url)}
            target="_blank"
            rel="noopener"
            class="btn btn-neutral btn-sm shrink-0"
          >
            <.icon name="hero-heart" class="size-4" /> Support Moorland
          </a>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
