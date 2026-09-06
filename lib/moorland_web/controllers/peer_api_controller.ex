defmodule MoorlandWeb.PeerApiController do
  @moduledoc """
  The wire between Moorland installations, in two endpoints. `hello`
  publishes this run's key-exchange key under the identity's signature;
  `envelope` takes one sealed, signed request from a known peer and answers
  inside the same envelope's reply key. Nothing about a script - not even
  its id - travels in the clear. The protocol is `Moorland.Peers.Envelope`.
  """

  use MoorlandWeb, :controller

  alias Moorland.Peers
  alias Moorland.Peers.{Envelope, Transport}
  alias Moorland.Scripts

  def hello(conn, _params), do: json(conn, Transport.hello())

  def envelope(conn, params) do
    case Transport.accept(params) do
      {:ok, request, peer, session} ->
        Peers.mark_seen(peer)
        {status, body} = handle(request["op"], request["args"] || %{}, peer)
        reply = Jason.encode!(%{status: status, body: body})
        json(conn, %{box: Envelope.seal_reply(session, reply)})

      {:error, :stale_kx} ->
        conn |> put_status(409) |> json(%{error: "stale_kx"})

      {:error, _reason} ->
        conn |> put_status(401) |> json(%{error: "unauthorized"})
    end
  end

  # Inner requests carry their own status so errors stay encrypted too.

  defp handle("shared", _args, peer) do
    {200, %{scripts: Scripts.peer_list_shared(peer.public_key)}}
  end

  defp handle("fetch", %{"id" => id}, peer) when is_integer(id) do
    case Scripts.peer_fetch(peer.public_key, id) do
      {:ok, payload} -> {200, payload}
      {:error, :not_shared} -> {404, %{error: "not shared"}}
    end
  end

  defp handle("save", %{"id" => id} = args, peer) when is_integer(id) do
    content = to_string(args["content"] || "")

    case Scripts.peer_save(peer.public_key, id, content, args["base_version"]) do
      {:ok, payload} -> {200, payload}
      {:error, :not_shared} -> {404, %{error: "not shared"}}
      {:error, :read_only} -> {403, %{error: "read only"}}
      {:error, _} -> {422, %{error: "could not save"}}
    end
  end

  defp handle("activity", %{"id" => id} = args, peer) when is_integer(id) do
    case Scripts.peer_activity(peer.public_key, id, args["after"]) do
      {:ok, payload} -> {200, payload}
      {:error, :not_shared} -> {404, %{error: "not shared"}}
    end
  end

  defp handle("activity_push", %{"id" => id, "activity" => activity}, peer)
       when is_integer(id) and is_map(activity) do
    case Scripts.peer_apply_activity(peer.public_key, id, activity) do
      {:ok, payload} -> {200, payload}
      {:error, :not_shared} -> {404, %{error: "not shared"}}
      {:error, :read_only} -> {403, %{error: "read only"}}
    end
  end

  # A peer telling us they changed something: sync now instead of waiting
  # for the next poll. This is what makes peer edits feel close to live.
  defp handle("notify", _args, _peer) do
    Moorland.Peers.Sync.sync_now()
    {200, %{ok: true}}
  end

  defp handle(_op, _args, _peer), do: {400, %{error: "unknown op"}}
end
