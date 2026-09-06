defmodule Moorland.PeersTest do
  use Moorland.DataCase

  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Peers
  alias Moorland.Peers.Crypto
  alias Moorland.Peers.Sync
  alias Moorland.Scripts

  describe "crypto" do
    test "sign/verify round-trips and rejects tampering" do
      %{public: pub, private: priv} = Crypto.generate_keypair()
      sig = Crypto.sign("hello", priv)
      assert Crypto.verify("hello", sig, pub)
      refute Crypto.verify("hell0", sig, pub)

      %{public: other_pub} = Crypto.generate_keypair()
      refute Crypto.verify("hello", sig, other_pub)
    end

    test "peer codes round-trip, including hosts with dots and dashes" do
      %{public: pub} = Crypto.generate_keypair()
      code = Crypto.format_code(pub, "moorland-abc123.local", 4000)
      assert {:ok, parsed} = Crypto.parse_code(code)
      assert parsed.public_key == pub
      assert parsed.host == "moorland-abc123.local"
      assert parsed.port == 4000
    end

    test "garbage codes are rejected" do
      assert {:error, :invalid_code} = Crypto.parse_code("not a code")
      assert {:error, :invalid_code} = Crypto.parse_code("moor:zz@host:notaport")
      assert {:error, :invalid_code} = Crypto.parse_code("moor:aGk@host:4000")
    end
  end

  describe "identity and peers" do
    setup do
      %{scope: Scope.for_user(user_fixture())}
    end

    test "identity is generated once and yields a stable code" do
      id1 = Peers.identity()
      id2 = Peers.identity()
      assert id1.id == id2.id
      assert byte_size(id1.public_key) == 32
      assert {:ok, parsed} = Crypto.parse_code(Peers.peer_code())
      assert parsed.public_key == id1.public_key
    end

    test "adding a peer by code; own code and duplicates rejected", %{scope: scope} do
      %{public: pub} = Crypto.generate_keypair()
      code = Crypto.format_code(pub, "10.0.0.7", 4000)

      assert {:ok, peer} = Peers.add_peer(scope, code, "Alex")
      assert peer.public_key == pub
      assert Peers.get_by_public_key(pub).id == peer.id

      assert {:error, %Ecto.Changeset{}} = Peers.add_peer(scope, code, "Alex again")
      assert {:error, :own_code} = Peers.add_peer(scope, Peers.peer_code(), "Me")
      assert {:error, :invalid_code} = Peers.add_peer(scope, "nope", "X")
    end
  end

  describe "peer sharing and peer saves (origin side)" do
    setup do
      scope = Scope.for_user(user_fixture())
      {:ok, script} = Scripts.create_script(scope, %{title: "Circle Draft", content: "base"})
      %{public: pub} = Crypto.generate_keypair()
      {:ok, peer} = Peers.add_peer(scope, Crypto.format_code(pub, "10.0.0.7", 4000), "Alex")
      %{scope: scope, script: script, peer: peer, pub: pub}
    end

    test "unshared scripts are invisible and unwritable", %{script: script, pub: pub} do
      assert Scripts.peer_list_shared(pub) == []
      assert {:error, :not_shared} = Scripts.peer_fetch(pub, script.id)
      assert {:error, :not_shared} = Scripts.peer_save(pub, script.id, "x", nil)
    end

    test "sharing exposes the script; viewer role blocks writes", %{
      scope: scope,
      script: script,
      peer: peer,
      pub: pub
    } do
      :ok = Scripts.set_peer_share(scope, script, peer.id, "viewer")
      assert [%{id: id, role: "viewer"}] = Scripts.peer_list_shared(pub)
      assert id == script.id
      assert {:ok, %{content: "base"}} = Scripts.peer_fetch(pub, script.id)
      assert {:error, :read_only} = Scripts.peer_save(pub, script.id, "x", nil)

      :ok = Scripts.set_peer_share(scope, script, peer.id, "editor")
      assert {:ok, %{content_version: 1}} = Scripts.peer_save(pub, script.id, "peer text", nil)

      :ok = Scripts.set_peer_share(scope, script, peer.id, "")
      assert Scripts.peer_list_shared(pub) == []
    end

    test "a stale peer save merges with local edits", %{scope: scope, script: script, peer: peer, pub: pub} do
      :ok = Scripts.set_peer_share(scope, script, peer.id, "editor")

      base = "INT. LAB - DAY\n\nThe machine hums.\n\nEXT. LOT - NIGHT\n\nRain falls."
      {:ok, s1} = Scripts.save_content(scope, script, base)

      # Local writer edits the top (built on version 1)...
      local = String.replace(base, "The machine hums.", "The machine roars.")
      {:ok, _} = Scripts.save_content(scope, s1, local, 1)

      # ...peer pushes an edit to the bottom, still based on version 1.
      remote = String.replace(base, "Rain falls.", "Snow falls.")
      assert {:ok, %{content: merged}} = Scripts.peer_save(pub, script.id, remote, 1)
      assert merged =~ "The machine roars."
      assert merged =~ "Snow falls."
    end
  end

  describe "sync planning (mirror side)" do
    test "no mirror yet means create" do
      assert Sync.plan(nil, 3) == :create
    end

    test "dirty mirror pushes even when the origin moved on" do
      mirror = %{content: "local edits", origin_content: "synced", origin_version: 2}
      assert Sync.plan(mirror, 5) == :push
    end

    test "clean mirror pulls when the origin is ahead" do
      mirror = %{content: "synced", origin_content: "synced", origin_version: 2}
      assert Sync.plan(mirror, 5) == :pull
    end

    test "clean and current means nothing to do" do
      mirror = %{content: "synced", origin_content: "synced", origin_version: 5}
      assert Sync.plan(mirror, 5) == :noop
    end
  end

  describe "mirrors" do
    setup do
      scope = Scope.for_user(user_fixture())
      %{public: pub} = Crypto.generate_keypair()
      {:ok, peer} = Peers.add_peer(scope, Crypto.format_code(pub, "10.0.0.7", 4000), "Alex")
      %{scope: scope, peer: peer, pub: pub}
    end

    test "create, pull, and role override", %{scope: scope, peer: peer, pub: pub} do
      {:ok, mirror} =
        Scripts.create_mirror(peer, %{
          "id" => 42,
          "title" => "Their Script",
          "content" => "v1 text",
          "content_version" => 1,
          "role" => "viewer"
        })

      assert Scripts.get_mirror(pub, 42).id == mirror.id

      # Locally owned, but read-only because the origin granted viewer.
      {_script, role} = Scripts.get_script!(scope, mirror.id)
      assert role == :viewer

      {:ok, updated} = Scripts.apply_origin_content(mirror, "Their Script", "v2 text", 2, "editor")
      assert updated.content == "v2 text"
      assert updated.origin_version == 2
      {_script, role} = Scripts.get_script!(scope, updated.id)
      assert role == :editor

      # Editable mirrors appear under "From peers" and are still deletable locally.
      assert {:ok, _} = Scripts.delete_script(scope, updated)
    end
  end
end
