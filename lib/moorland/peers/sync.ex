defmodule Moorland.Peers.Sync do
  @moduledoc """
  Background reconciler. Every interval it asks each known peer what they are
  sharing with us, mirrors new scripts locally, pulls remote changes, and
  pushes local edits back (the origin merges them three-way). All decisions
  flow through `plan/2` so the logic stays unit-testable.
  """

  use GenServer
  require Logger

  alias Moorland.Peers
  alias Moorland.Peers.Client
  alias Moorland.Scripts
  alias Moorland.Scripts.Activity

  @first_sync_ms 3_000
  @interval_ms 10_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Triggers an immediate sync pass (e.g. from the Peers page)."
  def sync_now do
    if Process.whereis(__MODULE__), do: send(__MODULE__, :sync)
    :ok
  end

  @impl true
  def init(nil) do
    Process.send_after(self(), :sync, @first_sync_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sync, state) do
    Enum.each(Peers.list_peers(), &sync_peer/1)
    Process.send_after(self(), :sync, @interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("peer sync failed: #{Exception.message(error)}")
      Process.send_after(self(), :sync, @interval_ms)
      {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp sync_peer(peer) do
    case Client.list_shared(peer) do
      {:ok, %{"scripts" => scripts}} ->
        Peers.mark_seen(peer)
        Enum.each(scripts, &reconcile(peer, &1))

      {:error, reason} ->
        Peers.mark_error(peer, describe(reason))
    end
  end

  @doc """
  Decides what to do for one shared script. `mirror` is the local copy (or
  nil), `remote_version` the origin's current content_version.

  Local edits win the tiebreak: a dirty mirror pushes first (the origin
  merges), and only a clean mirror pulls.
  """
  def plan(nil, _remote_version), do: :create

  def plan(mirror, remote_version) do
    cond do
      mirror.content != mirror.origin_content -> :push
      remote_version > mirror.origin_version -> :pull
      true -> :noop
    end
  end

  defp reconcile(peer, %{"id" => origin_id, "content_version" => remote_version} = meta) do
    mirror = Scripts.get_mirror(peer.public_key, origin_id)

    with {:ok, mirror} <- reconcile_content(peer, mirror, remote_version, meta) do
      reconcile_activity(peer, mirror, meta["activity"])
    end
  end

  defp reconcile_content(peer, mirror, remote_version, %{"id" => origin_id} = meta) do
    case plan(mirror, remote_version) do
      :create ->
        with {:ok, data} <- Client.fetch_script(peer, origin_id) do
          Scripts.create_mirror(peer, data)
        end

      :push ->
        case Client.push_save(peer, origin_id, mirror.content, mirror.origin_version) do
          {:ok, %{"content" => content, "content_version" => version}} ->
            Scripts.apply_origin_content(mirror, mirror.title, content, version, meta["role"])

          {:error, {403, _}} ->
            # Share was downgraded to read-only; surrender local divergence.
            pull_content(peer, mirror, origin_id)

          error ->
            error
        end

      :pull ->
        pull_content(peer, mirror, origin_id)

      :noop ->
        {:ok, mirror}
    end
  end

  defp pull_content(peer, mirror, origin_id) do
    with {:ok, data} <- Client.fetch_script(peer, origin_id) do
      Scripts.apply_origin_content(
        mirror,
        data["title"],
        data["content"],
        data["content_version"],
        data["role"]
      )
    end
  end

  # Comments, notes and history: push what changed here, then pull the
  # origin's view whenever its activity stamp moved (or we just pushed).
  defp reconcile_activity(peer, mirror, stamp) do
    pending = Activity.pending(mirror)

    pushed? =
      not Activity.empty?(pending) and
        case Client.push_activity(peer, mirror.origin_script_id, pending.payload) do
          {:ok, _} ->
            Activity.mark_synced(pending)
            true

          {:error, _} ->
            false
        end

    if pushed? or stamp != mirror.origin_activity_stamp do
      cursor = Activity.version_cursor(mirror)

      with {:ok, data} <- Client.fetch_activity(peer, mirror.origin_script_id, cursor) do
        Activity.apply_from_origin(mirror, data)
      end
    else
      {:ok, mirror}
    end
  end

  # Sync errors show on the Peers page; the common ones deserve plain words.
  defp describe(:peer_outdated),
    do: "runs an older Moorland without the encrypted wire - ask them to update"

  defp describe(:unauthorized),
    do:
      "refused our requests - they may not have added this installation, or clocks differ by over 5 minutes"

  defp describe(reason), do: inspect(reason)
end
