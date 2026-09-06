defmodule Moorland.ActivitySyncTest do
  # Both ends of the comments/notes/history sync, simulated in one database:
  # an origin script shared with peer "P", and a mirror of it held by a second
  # user who added the origin as peer "O". Payloads take the JSON round trip
  # they would take on the wire.
  use Moorland.DataCase

  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Peers
  alias Moorland.Peers.Crypto
  alias Moorland.Scripts
  alias Moorland.Scripts.Activity

  defp wire(map), do: map |> Jason.encode!() |> Jason.decode!()

  defp handle(%Scope{user: user}), do: user.email |> String.split("@") |> hd()

  # The mirror pulls whatever the origin would answer for its cursor.
  defp pull(mirror, origin) do
    {:ok, data} =
      Scripts.peer_activity(mirror_peer_key(), origin.id, Activity.version_cursor(mirror))

    {:ok, mirror} = Activity.apply_from_origin(mirror, wire(data))
    mirror
  end

  # The mirror pushes what is pending and, on success, marks it synced.
  defp push(mirror, origin) do
    pending = Activity.pending(mirror)
    result = Scripts.peer_apply_activity(mirror_peer_key(), origin.id, wire(pending.payload))
    if match?({:ok, _}, result), do: Activity.mark_synced(pending)
    result
  end

  defp mirror_peer_key, do: Process.get(:peer_key)

  setup do
    alice = Scope.for_user(user_fixture())
    bob = Scope.for_user(user_fixture())

    {:ok, origin} =
      Scripts.create_script(alice, %{title: "Shared Draft", content: "INT. HALL - DAY"})

    # Bob's installation, as Alice sees it.
    peer_keys = Crypto.generate_keypair()

    {:ok, peer} =
      Peers.add_peer(alice, Crypto.format_code(peer_keys.public, "10.0.0.2", 4000), "Bob")

    :ok = Scripts.set_peer_share(alice, origin, peer.id, "editor")
    Process.put(:peer_key, peer_keys.public)

    # Alice's installation, as Bob sees it, and his mirror of her script.
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

  test "the origin's comments, notes and history arrive on the mirror under peer handles", ctx do
    {:ok, top} = Scripts.create_comment(ctx.alice, ctx.origin, %{body: "Cut this?", line_no: 2})

    {:ok, _} =
      Scripts.create_comment(ctx.alice, ctx.origin, %{body: "Keep it", parent_id: top.id})

    {:ok, _} =
      Scripts.create_note(ctx.alice, ctx.origin, %{body: "Research halls", color: "blue"})

    {:ok, snapshot} = Scripts.create_snapshot(ctx.alice, ctx.origin, "First pass")

    mirror = pull(ctx.mirror, ctx.origin)

    assert [thread] = Scripts.list_comments(mirror)
    assert thread.body == "Cut this?"
    assert thread.line_no == 2
    assert thread.remote_author == handle(ctx.alice)
    assert thread.author == nil
    assert [%{body: "Keep it", remote_author: author}] = thread.replies
    assert author == handle(ctx.alice)

    assert [%{body: "Research halls", color: "blue", remote_author: note_author}] =
             Scripts.list_notes(mirror)

    assert note_author == handle(ctx.alice)

    assert [version] = Scripts.list_versions(mirror)
    assert version.message == "First pass"
    assert version.content == ctx.origin.content
    assert version.origin_id == snapshot.id
    assert Activity.version_cursor(mirror) == snapshot.id

    # Nothing that arrived is waiting to go back, and the first replay is quiet.
    assert Activity.empty?(Activity.pending(mirror))
    assert Scripts.unread_notifications(ctx.bob) == %{}
    assert is_binary(mirror.origin_activity_stamp)
  end

  test "work on the mirror pushes to the origin, then comes back as its own", ctx do
    {:ok, comment} = Scripts.create_comment(ctx.bob, ctx.mirror, %{body: "Love the hall"})
    {:ok, _} = Scripts.create_note(ctx.bob, ctx.mirror, %{body: "Ask about lighting"})
    {:ok, _} = Scripts.create_snapshot(ctx.bob, ctx.mirror, "Bob's pass")

    pending = Activity.pending(ctx.mirror)
    assert length(pending.payload.comments) == 1
    assert length(pending.payload.notes) == 1
    assert length(pending.payload.versions) == 1

    assert {:ok, _} = push(ctx.mirror, ctx.origin)
    assert Activity.empty?(Activity.pending(ctx.mirror))

    assert [%{body: "Love the hall", remote_author: author, author_id: nil, peer_key: key}] =
             Scripts.list_comments(ctx.origin)

    assert author == handle(ctx.bob)
    assert key == mirror_peer_key()
    assert [%{body: "Ask about lighting"}] = Scripts.list_notes(ctx.origin)
    assert [%{message: "Bob's pass", kind: "manual"}] = Scripts.list_versions(ctx.origin)

    # Alice hears about the comment; Bob does not hear about his own.
    assert Scripts.unread_notifications(ctx.alice) == %{ctx.origin.id => 1}

    # The echo keeps Bob as the local author and learns the origin's version id.
    mirror = pull(ctx.mirror, ctx.origin)
    assert [%{id: id, author_id: bob_id, remote_author: nil}] = Scripts.list_comments(mirror)
    assert id == comment.id
    assert bob_id == ctx.bob.user.id
    assert [%{origin_id: origin_id}] = Scripts.list_versions(mirror)
    assert is_integer(origin_id)
    assert Activity.empty?(Activity.pending(mirror))
  end

  test "resolving travels both ways and later comments notify the mirror's people", ctx do
    {:ok, top} = Scripts.create_comment(ctx.alice, ctx.origin, %{body: "Too long"})
    mirror = pull(ctx.mirror, ctx.origin)

    {:ok, _} = Scripts.resolve_comment(ctx.alice, ctx.origin, top.id, true)
    mirror = pull(mirror, ctx.origin)
    assert [%{resolved_at: %DateTime{}} = mirrored] = Scripts.list_comments(mirror)

    # Bob reopens it on his side: pending, pushed, applied at the origin.
    {:ok, _} = Scripts.resolve_comment(ctx.bob, mirror, mirrored.id, false)
    assert [_] = Activity.pending(mirror).payload.comments
    assert {:ok, _} = push(mirror, ctx.origin)
    assert [%{resolved_at: nil}] = Scripts.list_comments(ctx.origin)

    # A second comment from Alice, after the first replay, reaches Bob's inbox.
    {:ok, _} = Scripts.create_comment(ctx.alice, ctx.origin, %{body: "Also the ending"})
    _mirror = pull(mirror, ctx.origin)
    assert Scripts.unread_notifications(ctx.bob) == %{mirror.id => 1}
  end

  test "deletions travel both ways, but a peer only deletes what it wrote", ctx do
    {:ok, alices} = Scripts.create_comment(ctx.alice, ctx.origin, %{body: "Alice's"})
    {:ok, bobs} = Scripts.create_comment(ctx.bob, ctx.mirror, %{body: "Bob's"})
    assert {:ok, _} = push(ctx.mirror, ctx.origin)
    mirror = pull(ctx.mirror, ctx.origin)
    assert length(Scripts.list_comments(mirror)) == 2

    # Bob deletes his own synced comment: a tombstone goes to the origin.
    assert :ok = Scripts.delete_comment(ctx.bob, mirror, bobs.id)
    assert [%{kind: "comment"}] = Activity.pending(mirror).payload.deletions
    assert {:ok, _} = push(mirror, ctx.origin)
    assert [%{body: "Alice's"}] = Scripts.list_comments(ctx.origin)
    assert Activity.pending(mirror).payload.deletions == []

    # A forged deletion of Alice's comment is ignored.
    forged = %{"deletions" => [%{"kind" => "comment", "uid" => alices.uid}]}
    assert {:ok, _} = Scripts.peer_apply_activity(mirror_peer_key(), ctx.origin.id, forged)
    assert [%{body: "Alice's"}] = Scripts.list_comments(ctx.origin)

    # Alice deletes hers: the next pull drops it from the mirror.
    assert :ok = Scripts.delete_comment(ctx.alice, ctx.origin, alices.id)
    mirror = pull(mirror, ctx.origin)
    assert Scripts.list_comments(mirror) == []
  end

  test "local work still waiting to be pushed survives a pull", ctx do
    {:ok, note} = Scripts.create_note(ctx.bob, ctx.mirror, %{body: "Not pushed yet"})
    mirror = pull(ctx.mirror, ctx.origin)
    assert [%{id: id}] = Scripts.list_notes(mirror)
    assert id == note.id
    assert [_] = Activity.pending(mirror).payload.notes
  end

  test "a peer may change its own notes at the origin, not other people's", ctx do
    {:ok, _} = Scripts.create_note(ctx.alice, ctx.origin, %{body: "Alice's note"})
    {:ok, bobs} = Scripts.create_note(ctx.bob, ctx.mirror, %{body: "Bob's note"})
    assert {:ok, _} = push(ctx.mirror, ctx.origin)
    mirror = pull(ctx.mirror, ctx.origin)

    {:ok, _} =
      Scripts.update_note(ctx.bob, mirror, bobs.id, %{body: "Bob's note, edited", pinned: true})

    assert {:ok, _} = push(mirror, ctx.origin)
    bodies = Scripts.list_notes(ctx.origin) |> Enum.map(& &1.body) |> Enum.sort()
    assert bodies == ["Alice's note", "Bob's note, edited"]

    [alices_uid] =
      Scripts.list_notes(ctx.origin)
      |> Enum.filter(&(&1.body == "Alice's note"))
      |> Enum.map(& &1.uid)

    forged = %{"notes" => [%{"uid" => alices_uid, "body" => "vandalised", "author" => "bob"}]}
    assert {:ok, _} = Scripts.peer_apply_activity(mirror_peer_key(), ctx.origin.id, forged)
    assert Enum.any?(Scripts.list_notes(ctx.origin), &(&1.body == "Alice's note"))
  end

  test "viewer peers can read activity but not push it", ctx do
    :ok = Scripts.set_peer_share(ctx.alice, ctx.origin, ctx.peer.id, "viewer")
    assert {:ok, %{comments: []}} = Scripts.peer_activity(mirror_peer_key(), ctx.origin.id, 0)

    assert {:error, :read_only} =
             Scripts.peer_apply_activity(mirror_peer_key(), ctx.origin.id, %{"comments" => []})

    stranger = Crypto.generate_keypair()
    assert {:error, :not_shared} = Scripts.peer_activity(stranger.public, ctx.origin.id, 0)
  end

  test "the share list carries an activity stamp that moves when anything changes", ctx do
    [%{activity: before}] = Scripts.peer_list_shared(mirror_peer_key())
    assert is_binary(before)

    {:ok, _} = Scripts.create_note(ctx.alice, ctx.origin, %{body: "new"})
    [%{activity: after_note}] = Scripts.peer_list_shared(mirror_peer_key())
    assert after_note != before

    {:ok, _} = Scripts.create_snapshot(ctx.alice, ctx.origin, "v")
    [%{activity: after_snapshot}] = Scripts.peer_list_shared(mirror_peer_key())
    assert after_snapshot != after_note
  end

  test "malformed or hostile payloads are ignored, not applied", ctx do
    payload = %{
      "comments" => [
        %{"uid" => "no-body", "body" => "", "author" => "x"},
        %{"uid" => "orphan", "body" => "reply", "parent_uid" => "missing", "author" => "x"},
        "not a map",
        %{"body" => "no uid", "author" => "x"}
      ],
      "notes" => [%{"uid" => "bad-color", "body" => "ok", "color" => "neon", "author" => "x"}],
      "versions" => [%{"uid" => "auto-1", "kind" => "auto", "content" => "x", "author" => "x"}],
      "deletions" => "nope"
    }

    assert {:ok, _} = Scripts.peer_apply_activity(mirror_peer_key(), ctx.origin.id, payload)
    assert Scripts.list_comments(ctx.origin) == []
    assert [%{color: "yellow"}] = Scripts.list_notes(ctx.origin)
    assert Scripts.list_versions(ctx.origin) == []
  end
end
