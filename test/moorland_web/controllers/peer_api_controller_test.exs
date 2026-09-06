defmodule MoorlandWeb.PeerApiControllerTest do
  use MoorlandWeb.ConnCase

  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Peers
  alias Moorland.Peers.{Crypto, Envelope}
  alias Moorland.Scripts

  @skew 300

  setup %{conn: conn} do
    scope = Scope.for_user(user_fixture())
    {:ok, script} = Scripts.create_script(scope, %{title: "Wire Test", content: "hello"})

    keys = Crypto.generate_keypair()
    remote = %{public_key: keys.public, private_key: keys.private}

    {:ok, peer} =
      Peers.add_peer(scope, Crypto.format_code(keys.public, "10.0.0.9", 4000), "Remote")

    :ok = Scripts.set_peer_share(scope, script, peer.id, "editor")

    %{conn: conn, scope: scope, script: script, remote: remote, peer: peer}
  end

  # What a remote install does: learn our kx key from hello (trusting it only
  # under our identity's signature), seal a request, post it, open the reply.

  defp learn_kx(conn) do
    hello = get(conn, "/peer/api/hello") |> json_response(200)
    {:ok, kx} = Envelope.verify_hello(hello, Peers.identity().public_key, now(), @skew)
    kx
  end

  defp seal(remote, kx, op, args, ts \\ nil) do
    request = %{op: op, args: args, ts: ts || now()}
    Envelope.seal(Jason.encode!(request), remote, kx)
  end

  defp post_envelope(conn, envelope) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/peer/api/envelope", Jason.encode!(envelope))
  end

  defp call(conn, remote, op, args) do
    {envelope, session} = seal(remote, learn_kx(conn), op, args)
    resp = post_envelope(conn, envelope) |> json_response(200)
    {:ok, plaintext} = Envelope.open_reply(session, resp["box"])
    %{"status" => status, "body" => body} = Jason.decode!(plaintext)
    {status, body}
  end

  defp now, do: System.system_time(:second)

  test "hello is signed by this installation's identity", %{conn: conn} do
    hello = get(conn, "/peer/api/hello") |> json_response(200)
    assert {:ok, kx} = Envelope.verify_hello(hello, Peers.identity().public_key, now(), @skew)
    assert byte_size(kx) == 32

    stranger = Crypto.generate_keypair()
    assert {:error, :bad_hello} = Envelope.verify_hello(hello, stranger.public, now(), @skew)
  end

  test "a known peer can list, fetch and save through sealed envelopes", %{
    conn: conn,
    script: script,
    remote: remote
  } do
    assert {200, %{"scripts" => [%{"id" => id, "title" => "Wire Test", "role" => "editor"}]}} =
             call(conn, remote, "shared", %{})

    assert id == script.id

    assert {200, %{"content" => "hello", "content_version" => 0}} =
             call(conn, remote, "fetch", %{id: script.id})

    assert {200, %{"content" => "hello world", "content_version" => 1}} =
             call(conn, remote, "save", %{id: script.id, content: "hello world", base_version: 0})

    assert {200, %{"ok" => true}} = call(conn, remote, "notify", %{})
  end

  test "nothing about the script travels in the clear", %{
    conn: conn,
    script: script,
    remote: remote
  } do
    {envelope, _session} =
      seal(remote, learn_kx(conn), "save", %{id: script.id, content: "secret draft"})

    wire = Jason.encode!(envelope)
    refute wire =~ "secret draft"

    resp = post_envelope(conn, envelope)
    assert Map.keys(json_response(resp, 200)) == ["box"]
    refute resp.resp_body =~ "secret draft"
    refute resp.resp_body =~ "Wire Test"
  end

  test "errors are answered inside the envelope", %{
    conn: conn,
    scope: scope,
    script: script,
    remote: remote
  } do
    {:ok, private} = Scripts.create_script(scope, %{title: "Private", content: "mine"})
    assert {404, %{"error" => "not shared"}} = call(conn, remote, "fetch", %{id: private.id})

    [peer] = Peers.list_peers()
    :ok = Scripts.set_peer_share(scope, script, peer.id, "viewer")

    assert {403, %{"error" => "read only"}} =
             call(conn, remote, "save", %{id: script.id, content: "nope", base_version: 0})

    assert {400, %{"error" => "unknown op"}} = call(conn, remote, "format_disk", %{})
    assert {400, _} = call(conn, remote, "fetch", %{id: "not-an-id"})
  end

  test "comments, notes and history travel inside envelopes too", %{
    conn: conn,
    scope: scope,
    script: script,
    remote: remote
  } do
    {:ok, _} = Scripts.create_comment(scope, script, %{body: "from the origin"})

    assert {200, %{"comments" => [%{"body" => "from the origin", "uid" => uid}], "stamp" => _}} =
             call(conn, remote, "activity", %{id: script.id, after: 0})

    assert is_binary(uid)

    pushed = %{comments: [%{uid: "remote-1", body: "from the peer", author: "casey"}]}

    assert {200, %{"ok" => true}} =
             call(conn, remote, "activity_push", %{id: script.id, activity: pushed})

    assert Enum.any?(Scripts.list_comments(script), &(&1.remote_author == "casey"))

    [peer] = Peers.list_peers()
    :ok = Scripts.set_peer_share(scope, script, peer.id, "viewer")
    assert {403, _} = call(conn, remote, "activity_push", %{id: script.id, activity: pushed})
    assert {200, _} = call(conn, remote, "activity", %{id: script.id, after: 0})
    assert {404, _} = call(conn, remote, "activity", %{id: script.id + 1000, after: 0})
  end

  test "strangers are refused even with a valid envelope", %{conn: conn} do
    keys = Crypto.generate_keypair()
    stranger = %{public_key: keys.public, private_key: keys.private}
    {envelope, _} = seal(stranger, learn_kx(conn), "shared", %{})
    assert post_envelope(conn, envelope) |> json_response(401)
  end

  test "a forged signature is refused", %{conn: conn, remote: remote} do
    {envelope, _} = seal(remote, learn_kx(conn), "shared", %{})
    forged = %{envelope | sig: Crypto.encode_key(Crypto.sign("wrong", remote.private_key))}
    assert post_envelope(conn, forged) |> json_response(401)
  end

  test "an envelope sealed to a previous run's key gets stale_kx", %{conn: conn, remote: remote} do
    old_kx = Envelope.generate_kx()
    {envelope, _} = seal(remote, old_kx.public, "shared", %{})
    assert %{"error" => "stale_kx"} = post_envelope(conn, envelope) |> json_response(409)
  end

  test "a stale timestamp is refused", %{conn: conn, remote: remote} do
    {envelope, _} = seal(remote, learn_kx(conn), "shared", %{}, now() - 3_600)
    assert post_envelope(conn, envelope) |> json_response(401)
  end

  test "a replayed envelope is refused", %{conn: conn, remote: remote} do
    {envelope, _} = seal(remote, learn_kx(conn), "shared", %{})
    assert post_envelope(conn, envelope) |> json_response(200)
    assert post_envelope(conn, envelope) |> json_response(401)
  end

  test "garbage is refused", %{conn: conn} do
    assert post_envelope(conn, %{}) |> json_response(401)

    assert post_envelope(conn, %{from: "zz", eph: "zz", to: "zz", box: "zz", sig: "zz"})
           |> json_response(401)
  end
end
