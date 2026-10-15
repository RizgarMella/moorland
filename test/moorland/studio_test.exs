defmodule Moorland.StudioTest do
  use Moorland.DataCase

  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Peers
  alias Moorland.Peers.{Crypto, Sync}
  alias Moorland.Scripts

  defp add_peer(scope, name, host) do
    %{public: pub} = Crypto.generate_keypair()
    {:ok, peer} = Peers.add_peer(scope, Crypto.format_code(pub, host, 4000), name)
    peer
  end

  describe "owner side: shares routed through a studio" do
    setup do
      scope = Scope.for_user(user_fixture())
      {:ok, script} = Scripts.create_script(scope, %{title: "Moor", content: "base"})
      studio = add_peer(scope, "Studio", "10.0.0.2")
      {:ok, studio} = Peers.mark_seen(studio, studio: true)
      %{scope: scope, script: script, studio: studio, member: add_peer(scope, "Bea", "10.0.0.3")}
    end

    test "the member reads it from the studio, which gets the relay list", ctx do
      %{scope: scope, script: script, studio: studio, member: member} = ctx
      :ok = Scripts.set_peer_share(scope, script, member.id, "editor", studio.id)

      assert Scripts.list_peer_routes(script) == %{member.id => studio.id}

      # Not served to the member directly: they'd end up with two copies.
      assert Scripts.peer_list_shared(member.public_key) == []
      assert {:error, :not_shared} = Scripts.peer_fetch(member.public_key, script.id)

      member_key = Crypto.encode_key(member.public_key)

      assert [%{id: id, role: "editor", relay: [%{key: ^member_key, role: "editor"}]}] =
               Scripts.peer_list_shared(studio.public_key)

      assert id == script.id
      assert {:ok, %{content: "base"}} = Scripts.peer_fetch(studio.public_key, script.id)
      assert {:ok, _} = Scripts.peer_save(studio.public_key, script.id, "relayed edit", nil)

      # Switching back to direct delivery.
      :ok = Scripts.set_peer_share(scope, script, member.id, "editor", nil)
      assert [%{id: ^id}] = Scripts.peer_list_shared(member.public_key)
      assert Scripts.peer_list_shared(studio.public_key) == []
    end

    test "the studio acts under the strongest role it carries", ctx do
      %{scope: scope, script: script, studio: studio, member: member} = ctx
      other = add_peer(scope, "Cal", "10.0.0.4")
      :ok = Scripts.set_peer_share(scope, script, member.id, "viewer", studio.id)
      :ok = Scripts.set_peer_share(scope, script, other.id, "commenter", studio.id)

      assert [%{role: "commenter", relay: relay}] = Scripts.peer_list_shared(studio.public_key)
      assert length(relay) == 2
      assert {:error, :read_only} = Scripts.peer_save(studio.public_key, script.id, "x", nil)
    end

    test "only a studio among the owner's peers can carry a share", ctx do
      %{scope: scope, script: script, studio: studio, member: member} = ctx
      plain = add_peer(scope, "Plain", "10.0.0.5")

      assert {:error, :not_a_studio} =
               Scripts.set_peer_share(scope, script, member.id, "editor", plain.id)

      # Not through itself, and not through someone else's studio.
      assert {:error, :not_a_studio} =
               Scripts.set_peer_share(scope, script, studio.id, "editor", studio.id)

      stranger = Scope.for_user(user_fixture())
      {:ok, theirs} = Scripts.create_script(stranger, %{title: "Theirs"})
      them = add_peer(stranger, "Dee", "10.0.0.6")

      assert {:error, :not_a_studio} =
               Scripts.set_peer_share(stranger, theirs, them.id, "editor", studio.id)
    end
  end

  describe "studio side: relaying a mirror" do
    setup do
      {:ok, _} = Peers.set_studio(true)
      scope = Scope.for_user(user_fixture())
      origin = add_peer(scope, "Ana", "10.0.1.1")
      member = add_peer(scope, "Bea", "10.0.1.2")

      {:ok, mirror} =
        Scripts.create_mirror(origin, %{
          "id" => 7,
          "title" => "Moor",
          "content" => "INT. HOUSE - DAY\n\nQuiet.",
          "content_version" => 3,
          "role" => "editor"
        })

      %{scope: scope, origin: origin, member: member, mirror: mirror}
    end

    defp relay(peer, role), do: %{"key" => Crypto.encode_key(peer.public_key), "role" => role}

    test "members the studio knows get the mirror; strangers and the origin don't", ctx do
      %{origin: origin, member: member, mirror: mirror} = ctx
      %{public: stranger} = Crypto.generate_keypair()

      :ok =
        Scripts.sync_relay(mirror, [
          relay(member, "editor"),
          %{"key" => Crypto.encode_key(stranger), "role" => "editor"},
          relay(origin, "editor"),
          %{"key" => "not base64!", "role" => "editor"},
          relay(member, "owner")
        ])

      assert Scripts.list_peer_shares(mirror) == %{member.id => "editor"}
      assert [%{id: id, role: "editor"}] = Scripts.peer_list_shared(member.public_key)
      assert id == mirror.id

      :ok = Scripts.sync_relay(mirror, [relay(member, "viewer")])
      assert Scripts.list_peer_shares(mirror) == %{member.id => "viewer"}
    end

    test "a member's edit lands at the studio while the owner is away, then heads upstream",
         ctx do
      %{member: member, mirror: mirror} = ctx
      :ok = Scripts.sync_relay(mirror, [relay(member, "editor")])

      edit = "INT. HOUSE - DAY\n\nQuiet. A clock ticks."

      assert {:ok, %{content: ^edit}} =
               Scripts.peer_save(member.public_key, mirror.id, edit, mirror.content_version)

      mirror = Scripts.get_mirror(mirror.origin_public_key, 7)
      assert mirror.content == edit
      # The owner hasn't seen it: the next pass pushes it, merged against v3.
      assert mirror.origin_content != edit
      assert Sync.plan(mirror, 3) == :push
    end

    test "turning studio mode off, or the origin dropping the route, ends the relay", ctx do
      %{origin: origin, member: member, mirror: mirror} = ctx
      :ok = Scripts.sync_relay(mirror, [relay(member, "editor")])

      Scripts.drop_unlisted_relays(origin.public_key, [7])
      assert Scripts.list_peer_shares(mirror) == %{member.id => "editor"}

      Scripts.drop_unlisted_relays(origin.public_key, [])
      assert Scripts.list_peer_shares(mirror) == %{}

      :ok = Scripts.sync_relay(mirror, [relay(member, "editor")])
      {:ok, _} = Peers.set_studio(false)
      :ok = Scripts.sync_relay(mirror, [relay(member, "editor")])
      assert Scripts.list_peer_shares(mirror) == %{}
    end
  end
end
