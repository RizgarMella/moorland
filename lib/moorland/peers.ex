defmodule Moorland.Peers do
  @moduledoc """
  Peer-to-peer identity and trust for this installation.

  Every install generates an Ed25519 keypair on first use and exposes a
  shareable peer code (`moor:<key>@host:port`). Adding someone's code makes
  them a known peer; when both sides have added each other, scripts shared to
  a peer sync directly between the two installations - no central server.
  """

  import Ecto.Query, warn: false

  alias Moorland.Repo
  alias Moorland.Accounts.Scope
  alias Moorland.Peers.{Identity, Peer, Crypto}

  ## Identity

  @doc "This installation's identity, generated on first call."
  def identity do
    case Repo.one(from(i in Identity, limit: 1)) do
      %Identity{} = identity ->
        identity

      nil ->
        keys = Crypto.generate_keypair()

        Repo.insert!(%Identity{
          name: "My Moorland",
          public_key: keys.public,
          private_key: keys.private,
          host: default_host(),
          port: default_port()
        })
    end
  end

  def update_identity(attrs) do
    identity()
    |> Identity.changeset(attrs)
    |> Repo.update()
  end

  def peer_code do
    identity = identity()
    Crypto.format_code(identity.public_key, identity.host, identity.port)
  end

  def short_id, do: Crypto.fingerprint(identity().public_key)

  ## Peers

  def list_peers do
    Repo.all(from(p in Peer, order_by: [asc: p.name]))
  end

  @doc "Peers added by this user (peer trust is per-user, not per-install)."
  def list_peers(%Scope{user: user}) do
    Repo.all(from(p in Peer, where: p.added_by_user_id == ^user.id, order_by: [asc: p.name]))
  end

  @doc "Adds a peer straight from a LAN discovery beacon."
  def add_discovered_peer(%Scope{user: user}, %{
        public_key: public_key,
        name: name,
        host: host,
        port: port
      }) do
    if public_key == identity().public_key do
      {:error, :own_code}
    else
      %Peer{}
      |> Peer.changeset(%{
        name: name,
        public_key: public_key,
        host: host,
        port: port,
        added_by_user_id: user.id
      })
      |> Repo.insert()
    end
  end

  def get_peer!(id), do: Repo.get!(Peer, id)

  def get_by_public_key(public_key) when is_binary(public_key) do
    Repo.get_by(Peer, public_key: public_key)
  end

  @doc "Map of public_key => peer name, for labeling mirrored scripts."
  def names_by_key do
    Map.new(list_peers(), &{&1.public_key, &1.name})
  end

  def add_peer(%Scope{user: user}, code, name) do
    with {:ok, parsed} <- Crypto.parse_code(code) do
      cond do
        parsed.public_key == identity().public_key ->
          {:error, :own_code}

        true ->
          %Peer{}
          |> Peer.changeset(%{
            name: String.trim(to_string(name)),
            public_key: parsed.public_key,
            host: parsed.host,
            port: parsed.port,
            added_by_user_id: user.id
          })
          |> Repo.insert()
      end
    end
  end

  def remove_peer(%Scope{}, peer_id) do
    case Repo.get(Peer, peer_id) do
      nil -> {:error, :not_found}
      peer -> Repo.delete(peer)
    end
  end

  def mark_seen(%Peer{} = peer) do
    peer
    |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now(:second), last_error: nil)
    |> Repo.update()
  end

  def mark_error(%Peer{} = peer, reason) do
    peer
    |> Ecto.Changeset.change(last_error: String.slice(to_string(reason), 0, 200))
    |> Repo.update()
  end

  ## Defaults

  defp default_port do
    case Application.get_env(:moorland, MoorlandWeb.Endpoint)[:http] do
      config when is_list(config) -> Keyword.get(config, :port, 4000)
      _ -> 4000
    end
  end

  # Best guess at a LAN-reachable address; the user can change it any time.
  defp default_host do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        interfaces
        |> Enum.flat_map(fn {_name, opts} -> Keyword.get_values(opts, :addr) end)
        |> Enum.find(fn
          {a, _, _, _} when a != 127 -> true
          _ -> false
        end)
        |> case do
          {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
          _ -> "127.0.0.1"
        end

      _ ->
        "127.0.0.1"
    end
  end
end
