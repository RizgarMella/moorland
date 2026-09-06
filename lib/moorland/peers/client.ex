defmodule Moorland.Peers.Client do
  @moduledoc """
  Outbound side of the encrypted peer wire, over Erlang's built-in :httpc
  (no extra dependencies to package). Every call is one sealed envelope; the
  protocol lives in `Moorland.Peers.Envelope`.

  The first call to a peer fetches its signed `hello` to learn the current
  key-exchange key. When the peer has restarted since, it answers `stale_kx`
  and the call transparently re-learns the key and retries once.
  """

  alias Moorland.Peers.{Envelope, Peer, Transport}

  @request_timeout 8_000
  @connect_timeout 4_000

  def list_shared(%Peer{} = peer), do: call(peer, "shared", %{})

  def fetch_script(%Peer{} = peer, origin_script_id) do
    call(peer, "fetch", %{id: origin_script_id})
  end

  def push_save(%Peer{} = peer, origin_script_id, content, base_version) do
    call(peer, "save", %{id: origin_script_id, content: content, base_version: base_version})
  end

  @doc "Comments, notes and versions (after `after_version_id`) of a shared script."
  def fetch_activity(%Peer{} = peer, origin_script_id, after_version_id) do
    call(peer, "activity", %{id: origin_script_id, after: after_version_id})
  end

  @doc "Sends this mirror's pending comments, notes, snapshots and deletions."
  def push_activity(%Peer{} = peer, origin_script_id, activity) do
    call(peer, "activity_push", %{id: origin_script_id, activity: activity})
  end

  @doc "Fire-and-forget 'something changed, sync when you like' ping."
  def notify(%Peer{} = peer), do: call(peer, "notify", %{})

  defp call(peer, op, args, attempt \\ 1) do
    with {:ok, peer_kx} <- peer_kx(peer),
         {:ok, reply} <- exchange(peer, peer_kx, op, args) do
      case reply do
        %{"status" => 200, "body" => body} -> {:ok, body}
        %{"status" => status, "body" => body} -> {:error, {status, body}}
        _ -> {:error, :bad_reply}
      end
    else
      {:error, :stale_kx} when attempt == 1 ->
        Transport.forget_peer_kx(peer.public_key)
        call(peer, op, args, 2)

      error ->
        error
    end
  end

  defp peer_kx(peer) do
    case Transport.peer_kx(peer.public_key) do
      {:ok, kx} -> {:ok, kx}
      :unknown -> learn_kx(peer)
    end
  end

  # The hello is only trusted when signed by the identity in the peer code.
  defp learn_kx(peer) do
    with {:ok, 200, body} <- http(:get, peer, "/peer/api/hello", nil),
         {:ok, hello} <- Jason.decode(body),
         {:ok, kx} <-
           Envelope.verify_hello(
             hello,
             peer.public_key,
             now(),
             Transport.max_clock_skew_seconds()
           ) do
      Transport.remember_peer_kx(peer.public_key, kx)
      {:ok, kx}
    else
      # An install from before the encrypted wire has no hello endpoint.
      {:ok, 404, _body} -> {:error, :peer_outdated}
      {:ok, status, _body} -> {:error, {:hello, status}}
      {:error, %Jason.DecodeError{}} -> {:error, :bad_hello}
      error -> error
    end
  end

  defp exchange(peer, peer_kx, op, args) do
    {envelope, session} = Transport.seal(peer_kx, %{op: op, args: args})

    with {:ok, 200, body} <- http(:post, peer, "/peer/api/envelope", Jason.encode!(envelope)),
         {:ok, %{"box" => box}} <- Jason.decode(body),
         {:ok, plaintext} <- Envelope.open_reply(session, box),
         {:ok, reply} <- Jason.decode(plaintext) do
      {:ok, reply}
    else
      {:ok, 409, _body} -> {:error, :stale_kx}
      {:ok, 401, _body} -> {:error, :unauthorized}
      {:ok, status, body} -> {:error, {status, body}}
      {:ok, _other} -> {:error, :bad_reply}
      {:error, %Jason.DecodeError{}} -> {:error, :bad_reply}
      error -> error
    end
  end

  defp http(method, peer, path, body) do
    url = String.to_charlist("http://#{peer.host}:#{peer.port}#{path}")

    request =
      case method do
        :get -> {url, []}
        :post -> {url, [], ~c"application/json", body}
      end

    options = [timeout: @request_timeout, connect_timeout: @connect_timeout]

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_, status, _}, _headers, response}} -> {:ok, status, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp now, do: System.system_time(:second)
end
