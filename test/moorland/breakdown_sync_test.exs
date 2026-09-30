defmodule Moorland.BreakdownSyncTest do
  # Breakdown tags travelling between installations, simulated in one
  # database as in ActivitySyncTest: an origin script shared with peer "P"
  # and a mirror of it held by a second user. Payloads take the JSON round
  # trip they would take on the wire.
  use Moorland.DataCase

  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Peers
  alias Moorland.Peers.Crypto
  alias Moorland.Scripts
  alias Moorland.Scripts.Activity

  @content "INT. HALL - DAY\n\nA brass lamp glows beside a grandfather clock."

  defp wire(map), do: map |> Jason.encode!() |> Jason.decode!()

  defp pull(mirror, origin) do
    {:ok, data} = Scripts.peer_activity(peer_key(), origin.id, Activity.version_cursor(mirror))
    {:ok, mirror} = Activity.apply_from_origin(mirror, wire(data))
    mirror
  end

  defp push(mirror, origin) do
    pending = Activity.pending(mirror)
    result = Scripts.peer_apply_activity(peer_key(), origin.id, wire(pending.payload))
    if match?({:ok, _}, result), do: Activity.mark_synced(pending)
    result
  end

  defp peer_key, do: Process.get(:peer_key)

  defp tag(scope, script, name, anchor, category \\ "props") do
    {:ok, tag} =
      Scripts.create_breakdown_tag(scope, script, %{
        category: category,
        name: name,
        anchor_text: anchor,
        line_no: 2
      })

    tag
  end

  defp names(script), do: script |> Scripts.list_breakdown_tags() |> Enum.map(& &1.name)

  setup do
    alice = Scope.for_user(user_fixture())
    bob = Scope.for_user(user_fixture())
    {:ok, origin} = Scripts.create_script(alice, %{title: "Shared Draft", content: @content})

    peer_keys = Crypto.generate_keypair()

    {:ok, peer} =
      Peers.add_peer(alice, Crypto.format_code(peer_keys.public, "10.0.0.2", 4000), "Bob")

    :ok = Scripts.set_peer_share(alice, origin, peer.id, "editor")
    Process.put(:peer_key, peer_keys.public)

    origin_keys = Crypto.generate_keypair()

    {:ok, origin_peer} =
      Peers.add_peer(bob, Crypto.format_code(origin_keys.public, "10.0.0.1", 4000), "Alice")

    {:ok, mirror} =
      Scripts.create_mirror(origin_peer, %{
        "id" => origin.id,
        "title" => origin.title,
        "content" => origin.content,
        "content_version" => 0,
        "role" => "editor"
      })

    %{alice: alice, bob: bob, origin: origin, mirror: mirror, peer: peer}
  end

  test "the origin's tags arrive on the mirror under the author's handle", ctx do
    tag(ctx.alice, ctx.origin, "Brass lamp", "brass lamp")
    pull(ctx.mirror, ctx.origin)

    assert [arrived] = Scripts.list_breakdown_tags(ctx.mirror)

    assert %{name: "Brass lamp", category: "props", anchor_text: "brass lamp", line_no: 2} =
             arrived

    assert arrived.author_id == nil and is_binary(arrived.remote_author)
    assert arrived.synced_rev == arrived.rev
  end

  test "tags made on the mirror push to the origin and come back as its own", ctx do
    mine = tag(ctx.bob, ctx.mirror, "Grandfather clock", "grandfather clock")

    assert {:ok, _} = push(ctx.mirror, ctx.origin)
    assert names(ctx.origin) == ["Grandfather clock"]

    pull(ctx.mirror, ctx.origin)
    assert [%{id: id, synced_rev: 1}] = Scripts.list_breakdown_tags(ctx.mirror)
    assert id == mine.id
    assert Activity.empty?(Activity.pending(ctx.mirror))
  end

  test "deletions travel both ways, but a peer only deletes its own tags at the origin", ctx do
    theirs = tag(ctx.alice, ctx.origin, "Brass lamp", "brass lamp")
    mine = tag(ctx.bob, ctx.mirror, "Clock", "grandfather clock")
    {:ok, _} = push(ctx.mirror, ctx.origin)
    pull(ctx.mirror, ctx.origin)

    # Bob deletes his own tag and his copy of Alice's.
    :ok = Scripts.delete_breakdown_tag(ctx.bob, ctx.mirror, mine.id)
    [copy] = Scripts.list_breakdown_tags(ctx.mirror)
    :ok = Scripts.delete_breakdown_tag(ctx.bob, ctx.mirror, copy.id)
    {:ok, _} = push(ctx.mirror, ctx.origin)

    assert names(ctx.origin) == ["Brass lamp"]

    # Alice's tag comes back to the mirror; then she deletes it for real.
    pull(ctx.mirror, ctx.origin)
    assert names(ctx.mirror) == ["Brass lamp"]

    :ok = Scripts.delete_breakdown_tag(ctx.alice, ctx.origin, theirs.id)
    pull(ctx.mirror, ctx.origin)
    assert names(ctx.mirror) == []
  end

  test "renames of the peer's own tags reach the origin; others' are ignored", ctx do
    tag(ctx.alice, ctx.origin, "lamp", "brass lamp")
    tag(ctx.bob, ctx.mirror, "clock", "grandfather clock")
    {:ok, _} = push(ctx.mirror, ctx.origin)
    pull(ctx.mirror, ctx.origin)

    {:ok, 1} =
      Scripts.update_breakdown_element(ctx.bob, ctx.mirror, "props", "clock", %{
        name: "Clock",
        category: "set_dressing"
      })

    {:ok, 1} =
      Scripts.update_breakdown_element(ctx.bob, ctx.mirror, "props", "lamp", %{name: "Lamp"})

    {:ok, _} = push(ctx.mirror, ctx.origin)

    origin_tags = ctx.origin |> Scripts.list_breakdown_tags() |> Map.new(&{&1.uid, &1})

    assert Enum.any?(origin_tags, fn {_, t} ->
             t.name == "Clock" and t.category == "set_dressing"
           end)

    assert Enum.any?(origin_tags, fn {_, t} -> t.name == "lamp" end)

    # The origin's version of its own tag wins on the next pull.
    pull(ctx.mirror, ctx.origin)
    assert "lamp" in names(ctx.mirror)
  end

  test "local tags still waiting to be pushed survive a pull", ctx do
    tag(ctx.bob, ctx.mirror, "Clock", "grandfather clock")
    pull(ctx.mirror, ctx.origin)
    assert names(ctx.mirror) == ["Clock"]
  end

  test "an origin that sends no tag list leaves the mirror's tags alone", ctx do
    tag(ctx.alice, ctx.origin, "Brass lamp", "brass lamp")
    mirror = pull(ctx.mirror, ctx.origin)

    {:ok, data} = Scripts.peer_activity(peer_key(), ctx.origin.id, 0)
    {:ok, _} = Activity.apply_from_origin(mirror, data |> wire() |> Map.delete("tags"))

    assert names(ctx.mirror) == ["Brass lamp"]
  end

  test "the activity stamp moves when tags change", ctx do
    before = Activity.stamp(ctx.origin.id)
    tag(ctx.alice, ctx.origin, "Brass lamp", "brass lamp")
    refute Activity.stamp(ctx.origin.id) == before
  end

  test "tagging notifies subscribers on the other side", ctx do
    Scripts.subscribe(ctx.mirror.id)
    tag(ctx.alice, ctx.origin, "Brass lamp", "brass lamp")
    pull(ctx.mirror, ctx.origin)
    mirror_id = ctx.mirror.id
    assert_receive {:breakdown_changed, ^mirror_id}
  end

  test "malformed tags from a peer are ignored", ctx do
    payload = %{
      "tags" => [
        %{"uid" => "a", "category" => "snacks", "name" => "Crisps", "line_no" => 0},
        %{"uid" => "b", "category" => "props", "name" => "   ", "line_no" => 0},
        %{"category" => "props", "name" => "No uid", "line_no" => 0},
        %{"uid" => "c", "category" => "props", "name" => "Lamp", "line_no" => -4},
        "not a map"
      ]
    }

    {:ok, _} = Scripts.peer_apply_activity(peer_key(), ctx.origin.id, payload)
    assert [%{name: "Lamp", line_no: 0, uid: "c"}] = Scripts.list_breakdown_tags(ctx.origin)
  end

  test "viewer peers cannot push tags", ctx do
    :ok = Scripts.set_peer_share(ctx.alice, ctx.origin, ctx.peer.id, "viewer")
    payload = %{"tags" => [%{"uid" => "x", "category" => "props", "name" => "Lamp"}]}

    assert {:error, :read_only} = Scripts.peer_apply_activity(peer_key(), ctx.origin.id, payload)
    assert Scripts.list_breakdown_tags(ctx.origin) == []
  end
end
