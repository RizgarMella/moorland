defmodule Moorland.MediaLibraryTest do
  # The media library locally, and its items travelling between
  # installations, simulated in one database as in BreakdownSyncTest.
  use Moorland.DataCase

  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Peers
  alias Moorland.Peers.Crypto
  alias Moorland.Scripts
  alias Moorland.Scripts.Activity

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

  # What Sync does after a pull: fetch the files the mirror is missing.
  defp fetch_files(mirror, origin) do
    for uid <- Activity.missing_library_media(mirror) do
      {:ok, reply} = Scripts.peer_library_media(peer_key(), origin.id, uid)
      Activity.store_library_media(mirror, uid, wire(reply))
    end
  end

  defp peer_key, do: Process.get(:peer_key)

  defp upload(bytes) do
    path = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    path
  end

  defp read(script, item),
    do: File.read(Path.join(Moorland.Storage.media_dir(script.id), item.file))

  setup do
    alice = Scope.for_user(user_fixture())
    bob = Scope.for_user(user_fixture())

    {:ok, origin} =
      Scripts.create_script(alice, %{title: "Shared Draft", content: "INT. HALL - DAY"})

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

  describe "locally" do
    test "adds, describes, pins and removes files", ctx do
      {:ok, item} =
        Scripts.add_media(ctx.alice, ctx.origin, upload("PNG"), "Lighthouse at dusk.PNG")

      assert item.title == "Lighthouse at dusk"
      assert item.filename == "Lighthouse at dusk.PNG"
      assert item.size == 3
      assert item.board == ""
      assert read(ctx.origin, item) == {:ok, "PNG"}

      {:ok, item} =
        Scripts.update_media(ctx.alice, ctx.origin, item.id, %{
          caption: "Cold light",
          board: "  Coast  "
        })

      assert item.board == "Coast"
      assert Scripts.media_boards(ctx.origin) == ["Coast"]

      {:ok, item} = Scripts.update_media(ctx.alice, ctx.origin, item.id, %{board: ""})
      assert item.board == ""

      assert {:ok, _, _path, "image/png"} = Scripts.media_file(ctx.alice, ctx.origin, item.id)

      :ok = Scripts.delete_media(ctx.alice, ctx.origin, item.id)
      assert Scripts.list_media(ctx.origin) == []
      assert {:error, :enoent} = read(ctx.origin, item)
    end

    test "refuses unknown types and strangers", ctx do
      assert {:error, :unsupported} =
               Scripts.add_media(ctx.alice, ctx.origin, upload("x"), "notes.exe")

      assert {:error, :unsupported} =
               Scripts.add_media(ctx.alice, ctx.origin, upload("<svg/>"), "logo.svg")

      stranger = Scope.for_user(user_fixture())

      assert {:error, :not_allowed} =
               Scripts.add_media(stranger, ctx.origin, upload("x"), "a.png")
    end
  end

  describe "between installations" do
    test "the origin's files are named on pull and fetched after", ctx do
      {:ok, item} =
        Scripts.add_media(ctx.alice, ctx.origin, upload("PDFDATA"), "lookbook.pdf", %{
          board: "Look"
        })

      mirror = pull(ctx.mirror, ctx.origin)
      assert [%{uid: uid, board: "Look", title: "lookbook"} = here] = Scripts.list_media(mirror)
      assert uid == item.uid
      assert Activity.missing_library_media(mirror) == [uid]

      fetch_files(mirror, ctx.origin)
      assert read(mirror, here) == {:ok, "PDFDATA"}
      assert Activity.missing_library_media(mirror) == []

      # Recaptioned at the origin, recaptioned here; removed, removed here.
      {:ok, _} = Scripts.update_media(ctx.alice, ctx.origin, item.id, %{caption: "Palette"})
      mirror = pull(mirror, ctx.origin)
      assert [%{caption: "Palette"}] = Scripts.list_media(mirror)

      :ok = Scripts.delete_media(ctx.alice, ctx.origin, item.id)
      pull(mirror, ctx.origin)
      assert Scripts.list_media(mirror) == []
      assert {:error, :enoent} = read(mirror, here)
    end

    test "a mirror's own file travels inline; its deletion follows", ctx do
      {:ok, item} = Scripts.add_media(ctx.bob, ctx.mirror, upload("MP3DATA"), "temp track.mp3")

      {:ok, _} = push(ctx.mirror, ctx.origin)
      [there] = Scripts.list_media(ctx.origin)
      assert there.uid == item.uid
      assert there.remote_author
      assert read(ctx.origin, there) == {:ok, "MP3DATA"}

      mirror = pull(ctx.mirror, ctx.origin)
      assert Activity.missing_library_media(mirror) == []

      :ok = Scripts.delete_media(ctx.bob, mirror, item.id)
      {:ok, _} = push(mirror, ctx.origin)
      assert Scripts.list_media(ctx.origin) == []
      assert {:error, :enoent} = read(ctx.origin, there)
    end

    test "big files stay where they were added; the record still travels", ctx do
      big = :binary.copy("x", 3_100_000)
      {:ok, _} = Scripts.add_media(ctx.bob, ctx.mirror, upload(big), "location.mp4")

      {:ok, _} = push(ctx.mirror, ctx.origin)
      [there] = Scripts.list_media(ctx.origin)
      assert there.size == 3_100_000
      assert {:error, :enoent} = read(ctx.origin, there)
    end

    test "a peer may not change or delete what it did not add", ctx do
      {:ok, item} = Scripts.add_media(ctx.alice, ctx.origin, upload("PNG"), "a.png")

      payload = %{
        "media" => [%{"uid" => item.uid, "file" => item.file, "caption" => "hijacked"}],
        "deletions" => [%{"kind" => "media", "uid" => item.uid}]
      }

      {:ok, _} = Scripts.peer_apply_activity(peer_key(), ctx.origin.id, payload)
      assert [%{caption: ""}] = Scripts.list_media(ctx.origin)
      assert read(ctx.origin, item) == {:ok, "PNG"}
    end

    test "names that are not library names are ignored", ctx do
      payload = %{
        "media" => [
          %{"uid" => "evil", "file" => "../../moorland.db", "data" => Base.encode64("x")}
        ]
      }

      {:ok, _} = Scripts.peer_apply_activity(peer_key(), ctx.origin.id, payload)
      assert Scripts.list_media(ctx.origin) == []
    end
  end
end
