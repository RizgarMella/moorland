defmodule Moorland.Peers.ClientTest do
  # Drives the outbound client over a real HTTP listener that serves this
  # same installation, so hello, sealing, the reply path, and restart
  # recovery are exercised on the wire :httpc actually uses.
  use Moorland.DataCase

  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Peers
  alias Moorland.Peers.{Client, Envelope, Peer, Transport}
  alias Moorland.Scripts

  setup do
    # Under the test supervisor, so the listener stops with the test and no
    # late peer-notify request lands after the database sandbox is gone.
    server =
      start_supervised!(
        {Bandit, plug: MoorlandWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    scope = Scope.for_user(user_fixture())
    {:ok, script} = Scripts.create_script(scope, %{title: "Round Trip", content: "hello"})

    # This installation as its own peer: the loopback lets one process play
    # both ends without a second database.
    identity = Peers.identity()

    peer =
      Repo.insert!(%Peer{
        name: "Loopback",
        public_key: identity.public_key,
        host: "127.0.0.1",
        port: port,
        added_by_user_id: scope.user.id
      })

    :ok = Scripts.set_peer_share(scope, script, peer.id, "editor")
    on_exit(fn -> Transport.forget_peer_kx(identity.public_key) end)

    %{scope: scope, script: script, peer: peer}
  end

  test "hello, sealed calls, and replies travel over real HTTP", %{script: script, peer: peer} do
    assert :unknown = Transport.peer_kx(peer.public_key)

    assert {:ok, %{"scripts" => [%{"id" => id, "role" => "editor"}]}} = Client.list_shared(peer)
    assert id == script.id

    # The key learned from hello is this run's own kx key.
    assert {:ok, kx} = Transport.peer_kx(peer.public_key)
    assert kx == Transport.kx().public

    assert {:ok, %{"content" => "hello", "content_version" => 0}} =
             Client.fetch_script(peer, script.id)

    assert {:ok, %{"content" => "hello world", "content_version" => 1}} =
             Client.push_save(peer, script.id, "hello world", 0)

    assert {:ok, %{"ok" => true}} = Client.notify(peer)
    assert Peers.get_by_public_key(peer.public_key).last_seen_at
  end

  test "activity round-trips over real HTTP", %{scope: scope, script: script, peer: peer} do
    {:ok, _} = Scripts.create_note(scope, script, %{body: "origin note"})

    assert {:ok, %{"notes" => [%{"body" => "origin note"}], "comments" => [], "stamp" => stamp}} =
             Client.fetch_activity(peer, script.id, 0)

    assert is_binary(stamp)

    pushed = %{comments: [%{uid: "loop-1", body: "over the wire", author: "loop"}]}
    assert {:ok, %{"ok" => true}} = Client.push_activity(peer, script.id, pushed)
    assert [%{body: "over the wire", remote_author: "loop"}] = Scripts.list_comments(script)
  end

  test "a full sync pass mirrors a shared script with its comments over HTTP", %{
    scope: scope,
    script: script,
    peer: peer
  } do
    {:ok, _} = Scripts.create_comment(scope, script, %{body: "Read me on the other side"})
    {:ok, _} = Scripts.create_snapshot(scope, script, "Shared point")

    sync = start_supervised!(Moorland.Peers.Sync)
    send(sync, :sync)
    # get_state returns only after the :sync message has been handled.
    :sys.get_state(sync)

    mirror = Scripts.get_mirror(peer.public_key, script.id)
    assert %Moorland.Scripts.Script{} = mirror
    assert mirror.content == "hello"
    assert is_binary(mirror.origin_activity_stamp)

    handle = scope.user.email |> String.split("@") |> hd()

    assert [%{body: "Read me on the other side", remote_author: ^handle}] =
             Scripts.list_comments(mirror)

    assert [%{message: "Shared point", origin_id: origin_id}] = Scripts.list_versions(mirror)
    assert is_integer(origin_id)
    assert Peers.get_by_public_key(peer.public_key).last_error == nil
  end

  test "a peer that restarted is re-learned transparently", %{peer: peer} do
    # Pretend we remember the key from a previous run of the peer.
    Transport.remember_peer_kx(peer.public_key, Envelope.generate_kx().public)

    assert {:ok, %{"scripts" => [_]}} = Client.list_shared(peer)
    assert {:ok, kx} = Transport.peer_kx(peer.public_key)
    assert kx == Transport.kx().public
  end

  test "inner errors surface with their status", %{scope: scope, script: script, peer: peer} do
    :ok = Scripts.set_peer_share(scope, script, peer.id, "viewer")
    assert {:error, {403, %{"error" => "read only"}}} = Client.push_save(peer, script.id, "x", 0)

    assert {:error, {404, %{"error" => "not shared"}}} =
             Client.fetch_script(peer, script.id + 1000)
  end

  test "an unreachable peer is an error, not a crash", %{peer: peer} do
    assert {:error, _reason} = Client.list_shared(%{peer | port: 1})
  end
end
