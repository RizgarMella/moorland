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

  test "sketches travel as notes and stay sketches", ctx do
    {:ok, _} = Scripts.create_note(ctx.alice, ctx.origin, %{body: "A premise", kind: "sketch"})
    pull(ctx.mirror, ctx.origin)
    assert [%{kind: "sketch"}] = Scripts.list_notes(ctx.mirror)

    # A peer from before sketches sends notes without a kind.
    {:ok, data} = Scripts.peer_activity(peer_key(), ctx.origin.id, 0)
    data = wire(data)
    data = %{data | "notes" => Enum.map(data["notes"], &Map.delete(&1, "kind")), "stamp" => "x"}

    {:ok, _} =
      Activity.apply_from_origin(Moorland.Repo.get!(Moorland.Scripts.Script, ctx.mirror.id), data)

    assert [%{kind: "sketch"}] = Scripts.list_notes(ctx.mirror)
  end

  test "a commenter mirror comments and tags but cannot edit", ctx do
    :ok = Scripts.set_peer_share(ctx.alice, ctx.origin, ctx.peer.id, "commenter")

    {:ok, mirror} =
      Scripts.apply_origin_content(ctx.mirror, "Shared Draft", @content, 1, "commenter")

    assert {_s, :commenter} = Scripts.get_script!(ctx.bob, mirror.id)
    assert {:error, :not_allowed} = Scripts.save_content(ctx.bob, mirror, "rewritten")

    {:ok, _} = Scripts.create_comment(ctx.bob, mirror, %{body: "Lovely lamp"})
    tag(ctx.bob, mirror, "Lamp", "brass lamp")
    {:ok, _} = push(mirror, ctx.origin)

    assert [%{body: "Lovely lamp"}] = Scripts.list_comments(ctx.origin)
    assert names(ctx.origin) == ["Lamp"]
  end

  test "shots travel both ways; a peer changes only its own", ctx do
    {:ok, theirs} =
      Scripts.create_shot(ctx.alice, ctx.origin, %{
        anchor_text: "brass lamp",
        line_no: 2,
        size: "WS"
      })

    {:ok, _mine} =
      Scripts.create_shot(ctx.bob, ctx.mirror, %{
        anchor_text: "grandfather clock",
        line_no: 2,
        size: "CU"
      })

    {:ok, _} = push(ctx.mirror, ctx.origin)
    mirror = pull(ctx.mirror, ctx.origin)

    assert ctx.origin |> Scripts.list_shots() |> Enum.map(& &1.size) |> Enum.sort() == [
             "CU",
             "WS"
           ]

    assert mirror |> Scripts.list_shots() |> length() == 2

    # Bob's change to Alice's shot does not stick at the origin.
    copy = Enum.find(Scripts.list_shots(mirror), &(&1.uid == theirs.uid))
    {:ok, _} = Scripts.update_shot(ctx.bob, mirror, copy.id, %{"size" => "ECU"})
    {:ok, _} = push(mirror, ctx.origin)
    assert Enum.find(Scripts.list_shots(ctx.origin), &(&1.uid == theirs.uid)).size == "WS"

    :ok = Scripts.delete_shot(ctx.alice, ctx.origin, theirs.id)
    pull(mirror, ctx.origin)
    assert mirror |> Scripts.list_shots() |> Enum.map(& &1.size) == ["CU"]
  end

  test "tasks travel both ways; peers may move anyone's, edit only their own", ctx do
    {:ok, theirs} =
      Scripts.create_task(ctx.alice, ctx.origin, %{
        title: "Book the lighthouse",
        due_on: ~D[2026-10-12]
      })

    {:ok, _mine} =
      Scripts.create_task(ctx.bob, ctx.mirror, %{title: "Hire a boat", assignee: "Bob"})

    {:ok, _} = push(ctx.mirror, ctx.origin)
    mirror = pull(ctx.mirror, ctx.origin)

    assert ctx.origin |> Scripts.list_tasks() |> Enum.map(& &1.title) |> Enum.sort() == [
             "Book the lighthouse",
             "Hire a boat"
           ]

    copy = Enum.find(Scripts.list_tasks(mirror), &(&1.uid == theirs.uid))
    assert copy.due_on == ~D[2026-10-12]

    # Bob moves Alice's task and renames it: the move sticks, the rename does not.
    {:ok, _} = Scripts.set_task_status(ctx.bob, mirror, copy.id, "done")
    copy = Enum.find(Scripts.list_tasks(mirror), &(&1.uid == theirs.uid))
    Moorland.Repo.update!(Ecto.Changeset.change(copy, title: "Renamed", rev: copy.rev + 1))
    {:ok, _} = push(mirror, ctx.origin)

    at_origin = Enum.find(Scripts.list_tasks(ctx.origin), &(&1.uid == theirs.uid))
    assert at_origin.status == "done" and at_origin.title == "Book the lighthouse"

    :ok = Scripts.delete_task(ctx.alice, ctx.origin, theirs.id)
    pull(mirror, ctx.origin)
    assert mirror |> Scripts.list_tasks() |> Enum.map(& &1.title) == ["Hire a boat"]
  end

  describe "revision sets" do
    defp sets(script), do: script |> Scripts.list_revision_sets() |> Enum.map(& &1.color)
    defp fresh(script), do: Moorland.Repo.get!(Moorland.Scripts.Script, script.id)

    test "the origin's sets reach the mirror with their base text", ctx do
      {:ok, blue} = Scripts.start_revision(ctx.alice, ctx.origin)
      pull(ctx.mirror, ctx.origin)

      assert [copy] = Scripts.list_revision_sets(ctx.mirror)
      assert %{color: "Blue", base_content: base, synced_at: %DateTime{}} = copy
      assert base == blue.base_content and copy.uid == blue.uid
      assert DateTime.compare(copy.inserted_at, blue.inserted_at) == :eq
    end

    test "a set started on an editor mirror reaches the origin", ctx do
      {:ok, _} = Scripts.start_revision(ctx.bob, fresh(ctx.mirror))
      assert {:ok, _} = push(fresh(ctx.mirror), ctx.origin)
      assert sets(ctx.origin) == ["Blue"]
      assert Activity.empty?(Activity.pending(fresh(ctx.mirror)))

      pull(fresh(ctx.mirror), ctx.origin)
      assert sets(ctx.mirror) == ["Blue"]
    end

    test "ending revision mode on either side ends it everywhere", ctx do
      {:ok, _} = Scripts.start_revision(ctx.alice, ctx.origin)
      pull(ctx.mirror, ctx.origin)

      # From the mirror...
      :ok = Scripts.clear_revisions(ctx.bob, fresh(ctx.mirror))
      {:ok, _} = push(fresh(ctx.mirror), ctx.origin)
      assert sets(ctx.origin) == []

      # ...and from the origin.
      {:ok, _} = Scripts.start_revision(ctx.alice, ctx.origin)
      pull(fresh(ctx.mirror), ctx.origin)
      assert sets(ctx.mirror) == ["Blue"]
      :ok = Scripts.clear_revisions(ctx.alice, ctx.origin)
      pull(fresh(ctx.mirror), ctx.origin)
      assert sets(ctx.mirror) == []
    end

    test "locked pages follow the origin", ctx do
      pages = [%{"page" => "2", "line" => 3}]
      {:ok, origin} = Scripts.lock_pages(ctx.alice, ctx.origin, "BASE", pages)
      pull(ctx.mirror, origin)
      assert fresh(ctx.mirror).page_lock == %{"base" => "BASE", "pages" => pages}

      # An origin from before page locks says nothing, and nothing changes.
      {:ok, data} = Scripts.peer_activity(peer_key(), origin.id, 0)

      {:ok, _} =
        Activity.apply_from_origin(fresh(ctx.mirror), data |> wire() |> Map.delete("page_lock"))

      assert fresh(ctx.mirror).page_lock != nil

      {:ok, _} = Scripts.unlock_pages(ctx.alice, origin)
      pull(fresh(ctx.mirror), origin)
      assert fresh(ctx.mirror).page_lock == nil
    end

    test "commenter peers can neither start nor end revisions", ctx do
      {:ok, blue} = Scripts.start_revision(ctx.alice, ctx.origin)
      :ok = Scripts.set_peer_share(ctx.alice, ctx.origin, ctx.peer.id, "commenter")

      payload = %{
        "revision_sets" => [%{"uid" => "x", "color" => "Pink", "base_content" => ""}],
        "deletions" => [%{"kind" => "revision_set", "uid" => blue.uid}]
      }

      assert {:ok, _} = Scripts.peer_apply_activity(peer_key(), ctx.origin.id, payload)
      assert sets(ctx.origin) == ["Blue"]
    end
  end

  describe "storyboard frames" do
    defp frame_file(bytes) do
      path = Path.join(System.tmp_dir!(), "frame-#{System.unique_integer([:positive])}.png")
      File.write!(path, bytes)
      path
    end

    defp frame(script) do
      [shot | _] = Scripts.list_shots(script)
      shot.image && File.read(Path.join(Moorland.Storage.media_dir(script.id), shot.image))
    end

    # What Sync does after a pull: fetch frames the mirror is missing.
    defp fetch_frames(mirror, origin) do
      for uid <- Activity.missing_media(mirror) do
        {:ok, reply} = Scripts.peer_media(peer_key(), origin.id, uid)
        Activity.store_media(mirror, uid, wire(reply))
      end
    end

    test "the origin's frame is named on pull and fetched after", ctx do
      {:ok, shot} =
        Scripts.create_shot(ctx.alice, ctx.origin, %{anchor_text: "brass lamp", line_no: 2})

      {:ok, _} =
        Scripts.attach_shot_image(ctx.alice, ctx.origin, shot.id, frame_file("PNGDATA"), ".png")

      mirror = pull(ctx.mirror, ctx.origin)
      assert [%{image: name}] = Scripts.list_shots(mirror)
      assert is_binary(name)
      assert Activity.missing_media(mirror) == [shot.uid]

      fetch_frames(mirror, ctx.origin)
      assert frame(mirror) == {:ok, "PNGDATA"}
      assert Activity.missing_media(mirror) == []

      # Removed at the origin, removed here.
      {:ok, _} = Scripts.remove_shot_image(ctx.alice, ctx.origin, shot.id)
      pull(mirror, ctx.origin)
      assert [%{image: nil}] = Scripts.list_shots(mirror)
    end

    test "a mirror's own frame travels inline with its shot", ctx do
      {:ok, shot} =
        Scripts.create_shot(ctx.bob, ctx.mirror, %{anchor_text: "grandfather clock", line_no: 2})

      {:ok, _} =
        Scripts.attach_shot_image(ctx.bob, ctx.mirror, shot.id, frame_file("JPEGDATA"), ".jpg")

      {:ok, _} = push(ctx.mirror, ctx.origin)
      assert frame(ctx.origin) == {:ok, "JPEGDATA"}

      # Pulled back, nothing is fetched twice.
      mirror = pull(ctx.mirror, ctx.origin)
      assert Activity.missing_media(mirror) == []
    end

    test "frames over the size limit stay where they were made", ctx do
      {:ok, shot} =
        Scripts.create_shot(ctx.bob, ctx.mirror, %{anchor_text: "grandfather clock", line_no: 2})

      big = :binary.copy("x", 3_100_000)
      {:ok, _} = Scripts.attach_shot_image(ctx.bob, ctx.mirror, shot.id, frame_file(big), ".png")

      {:ok, _} = push(ctx.mirror, ctx.origin)
      [origin_shot] = Scripts.list_shots(ctx.origin)
      assert is_binary(origin_shot.image)
      assert {:error, :enoent} = frame(ctx.origin)
    end

    test "names that are not frame names are ignored", ctx do
      payload = %{
        "shots" => [
          %{
            "uid" => "evil",
            "line_no" => 0,
            "image" => "../../etc/passwd",
            "image_data" => Base.encode64("x")
          }
        ]
      }

      {:ok, _} = Scripts.peer_apply_activity(peer_key(), ctx.origin.id, payload)
      assert [%{image: nil}] = Scripts.list_shots(ctx.origin)
    end
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

  describe "stripboard" do
    @board_content "INT. HALL - DAY\n\nA brass lamp glows.\n\nEXT. PORCH - NIGHT\n\nRain."

    setup ctx do
      {:ok, origin} = Scripts.save_content(ctx.alice, ctx.origin, @board_content)
      {:ok, mirror} = Scripts.apply_origin_content(ctx.mirror, origin.title, @board_content, 1)
      %{origin: origin, mirror: mirror}
    end

    defp board(script) do
      script
      |> Scripts.list_schedule_items()
      |> Enum.map(fn i -> {i.kind, i.heading, i.note} end)
    end

    defp mirror_script(ctx), do: Moorland.Repo.get!(Moorland.Scripts.Script, ctx.mirror.id)

    test "the origin's board arrives on the mirror, dates and calls included", ctx do
      {:ok, _} =
        Scripts.schedule_scene(ctx.alice, ctx.origin, %{heading: "EXT. PORCH - NIGHT", line_no: 4})

      {:ok, day} = Scripts.add_day_break(ctx.alice, ctx.origin)

      {:ok, _} =
        Scripts.update_day_break(ctx.alice, ctx.origin, day.id, %{
          "shoot_date" => "2026-10-12",
          "note" => "Night",
          "crew_call" => "17:00",
          "cast_calls" => %{"ANNA" => "18:00"}
        })

      pull(ctx.mirror, ctx.origin)

      assert board(ctx.mirror) == [{"scene", "EXT. PORCH - NIGHT", nil}, {"day", nil, "Night"}]
      [_, mirrored] = Scripts.list_schedule_items(ctx.mirror)

      assert %{shoot_date: ~D[2026-10-12], crew_call: "17:00", cast_calls: %{"ANNA" => "18:00"}} =
               mirrored

      # Reordered and trimmed at the origin, the mirror follows.
      [strip, _] = Scripts.list_schedule_items(ctx.origin)
      :ok = Scripts.remove_schedule_item(ctx.alice, ctx.origin, strip.id)
      pull(ctx.mirror, ctx.origin)
      assert board(ctx.mirror) == [{"day", nil, "Night"}]
    end

    test "an editor's board on the mirror pushes to the origin", ctx do
      {:ok, _} =
        Scripts.schedule_scene(ctx.bob, ctx.mirror, %{heading: "INT. HALL - DAY", line_no: 0})

      {:ok, _} = Scripts.add_day_break(ctx.bob, ctx.mirror, %{note: "Day one"})

      refute Activity.empty?(Activity.pending(mirror_script(ctx)))
      assert {:ok, _} = push(mirror_script(ctx), ctx.origin)
      assert Activity.empty?(Activity.pending(mirror_script(ctx)))

      assert board(ctx.origin) == [{"scene", "INT. HALL - DAY", nil}, {"day", nil, "Day one"}]

      # And it comes back unchanged, uids intact.
      uids = Enum.map(Scripts.list_schedule_items(ctx.mirror), & &1.uid)
      pull(mirror_script(ctx), ctx.origin)
      assert Enum.map(Scripts.list_schedule_items(ctx.mirror), & &1.uid) == uids
    end

    test "a pull does not overwrite a board still waiting to be pushed", ctx do
      {:ok, _} =
        Scripts.schedule_scene(ctx.alice, ctx.origin, %{heading: "EXT. PORCH - NIGHT", line_no: 4})

      {:ok, _} =
        Scripts.schedule_scene(ctx.bob, ctx.mirror, %{heading: "INT. HALL - DAY", line_no: 0})

      pull(mirror_script(ctx), ctx.origin)
      assert board(ctx.mirror) == [{"scene", "INT. HALL - DAY", nil}]

      # Once pushed, the mirror's board is the board everywhere.
      {:ok, _} = push(mirror_script(ctx), ctx.origin)
      pull(mirror_script(ctx), ctx.origin)
      assert board(ctx.origin) == [{"scene", "INT. HALL - DAY", nil}]
      assert board(ctx.mirror) == board(ctx.origin)
    end

    test "an origin that sends no board leaves the mirror's alone", ctx do
      {:ok, _} =
        Scripts.schedule_scene(ctx.alice, ctx.origin, %{heading: "EXT. PORCH - NIGHT", line_no: 4})

      mirror = pull(ctx.mirror, ctx.origin)

      {:ok, data} = Scripts.peer_activity(peer_key(), ctx.origin.id, 0)
      {:ok, _} = Activity.apply_from_origin(mirror, data |> wire() |> Map.delete("schedule"))
      assert board(ctx.mirror) == [{"scene", "EXT. PORCH - NIGHT", nil}]
    end

    test "viewer mirrors cannot change the board", ctx do
      :ok = Scripts.set_peer_share(ctx.alice, ctx.origin, ctx.peer.id, "viewer")
      payload = %{"schedule" => [%{"uid" => "x", "kind" => "day"}]}

      assert {:error, :read_only} =
               Scripts.peer_apply_activity(peer_key(), ctx.origin.id, payload)

      assert board(ctx.origin) == []
    end

    test "malformed board items from a peer are skipped", ctx do
      payload = %{
        "schedule" => [
          %{"uid" => "a", "kind" => "scene", "heading" => "INT. HALL - DAY", "line_no" => 0},
          %{"uid" => "b", "kind" => "scene", "heading" => nil},
          %{"uid" => "c", "kind" => "day", "crew_call" => "late"},
          %{"uid" => "d", "kind" => "meeting"},
          %{"kind" => "day"},
          %{"uid" => "a", "kind" => "day"},
          %{"uid" => "e", "kind" => "day", "cast_calls" => %{"ANNA" => "07:00", "BEN" => "x"}}
        ]
      }

      {:ok, _} = Scripts.peer_apply_activity(peer_key(), ctx.origin.id, payload)

      assert [%{uid: "a", kind: "scene", position: 0}, %{uid: "e", cast_calls: calls}] =
               Scripts.list_schedule_items(ctx.origin)

      assert calls == %{"ANNA" => "07:00"}
    end

    test "the activity stamp moves when the board changes", ctx do
      before = Activity.stamp(ctx.origin.id)
      {:ok, _} = Scripts.add_day_break(ctx.alice, ctx.origin)
      refute Activity.stamp(ctx.origin.id) == before
    end
  end
end
