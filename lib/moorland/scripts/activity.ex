defmodule Moorland.Scripts.Activity do
  @moduledoc """
  Comments, notes and version history travelling between installations.

  The origin holds the truth for a script. A mirror pushes what its own
  users did - new or changed comments and notes, named snapshots, and
  deletions - then pulls the origin's full comment and note lists plus any
  versions it has not seen. Records match by `uid`. A record whose author
  lives on another installation carries a display handle in `remote_author`
  and no local user.

  "Still to push" is a revision counter, not a timestamp: every local change
  to a comment or note bumps `rev`, a successful push records that number in
  `synced_rev`, and the two differing means the origin is behind. Resolving
  someone else's comment therefore travels like anything else.

  Trust on the origin side: a peer may add records and resolve any comment,
  but change or delete only records that arrived from that same peer.
  """

  import Ecto.Query, warn: false

  alias Moorland.Repo
  alias Moorland.Peers.Peer
  alias Moorland.Scripts
  alias Moorland.Scripts.{Comment, Note, Script, Version}

  # Mirrors push named snapshots and restore points; automatic snapshots are
  # local noise (the origin lays down its own on every merged save).
  @pushed_version_kinds ~w(manual restore)
  @version_kinds ~w(manual auto restore)
  @max_body 5_000

  ## Origin side

  @doc "A change fingerprint for the share list; mirrors pull only when it moves."
  def stamp(script_id) do
    {comment_count, comment_max} =
      Repo.one(
        from(c in Comment,
          where: c.script_id == ^script_id,
          select: {count(c.id), max(c.updated_at)}
        )
      )

    {note_count, note_max} =
      Repo.one(
        from(n in Note,
          where: n.script_id == ^script_id,
          select: {count(n.id), max(n.updated_at)}
        )
      )

    version_max =
      Repo.one(from(v in Version, where: v.script_id == ^script_id, select: max(v.id)))

    "c#{comment_count}@#{stamp_part(comment_max)}|n#{note_count}@#{stamp_part(note_max)}|v#{version_max || 0}"
  end

  @doc "All comments and notes, plus versions after `after_id`, for a peer that may see the script."
  def for_peer(%Script{} = script, after_id) do
    after_id = if is_integer(after_id), do: after_id, else: 0

    comments =
      Repo.all(
        from(c in Comment,
          where: c.script_id == ^script.id,
          order_by: [asc: c.id],
          preload: [:author, :parent]
        )
      )

    notes =
      Repo.all(
        from(n in Note,
          where: n.script_id == ^script.id,
          order_by: [asc: n.id],
          preload: [:author]
        )
      )

    versions =
      Repo.all(
        from(v in Version,
          where: v.script_id == ^script.id and v.id > ^after_id,
          order_by: [asc: v.id],
          preload: [:author]
        )
      )

    %{
      stamp: stamp(script.id),
      comments: Enum.map(comments, &comment_payload/1),
      notes: Enum.map(notes, &note_payload/1),
      versions: Enum.map(versions, &version_payload/1)
    }
  end

  @doc "Applies activity pushed by an editor peer. Broadcasts and nudges other peers on change."
  def apply_from_peer(%Peer{public_key: key}, %Script{} = script, payload) when is_map(payload) do
    comments? =
      Enum.reduce(list(payload, "comments"), false, fn item, acc ->
        case find(Comment, script.id, item["uid"]) do
          nil ->
            case insert_comment(script, item, key, :origin) do
              {:ok, comment} ->
                Scripts.notify_comment(script, comment, nil)
                true

              :skip ->
                acc
            end

          %Comment{} = existing ->
            apply_resolution(existing, item, :origin) or acc
        end
      end)

    notes? =
      Enum.reduce(list(payload, "notes"), false, fn item, acc ->
        case find(Note, script.id, item["uid"]) do
          nil -> insert_note(script, item, key, :origin) == :ok or acc
          %Note{peer_key: ^key} = existing -> apply_note_fields(existing, item, :origin) or acc
          %Note{} -> acc
        end
      end)

    versions? =
      Enum.reduce(list(payload, "versions"), false, fn item, acc ->
        if item["kind"] in @pushed_version_kinds and find(Version, script.id, item["uid"]) == nil,
          do: insert_version(script, item, key, []) == :ok or acc,
          else: acc
      end)

    {comments_deleted?, notes_deleted?} =
      Enum.reduce(list(payload, "deletions"), {false, false}, fn item, {c, n} ->
        case {item["kind"], item["uid"]} do
          {"comment", uid} -> {delete_own(Comment, script.id, uid, key) or c, n}
          {"note", uid} -> {c, delete_own(Note, script.id, uid, key) or n}
          _ -> {c, n}
        end
      end)

    changed =
      announce(script, comments? or comments_deleted?, notes? or notes_deleted?, versions?)

    if changed, do: Scripts.nudge_peers(script)
    :ok
  end

  ## Mirror side

  @doc """
  Remembers a deletion the origin still has to hear about: only on mirrors,
  and only for records the origin has already received.
  """
  def remember_deletion(
        %Script{origin_public_key: key} = script,
        kind,
        %{synced_rev: synced} = record
      )
      when is_binary(key) and synced > 0 do
    Repo.insert_all("peer_deletions", [
      %{script_id: script.id, kind: kind, uid: record.uid, inserted_at: DateTime.utc_now(:second)}
    ])

    :ok
  end

  def remember_deletion(_script, _kind, _record), do: :ok

  @doc "What a mirror still has to push: a wire payload plus a receipt for `mark_synced/1`."
  def pending(%Script{} = mirror) do
    comments =
      Repo.all(
        from(c in Comment,
          where: c.script_id == ^mirror.id and c.rev > c.synced_rev,
          order_by: [asc: c.id],
          preload: [:author, :parent]
        )
      )

    notes =
      Repo.all(
        from(n in Note,
          where: n.script_id == ^mirror.id and n.rev > n.synced_rev,
          order_by: [asc: n.id],
          preload: [:author]
        )
      )

    versions =
      Repo.all(
        from(v in Version,
          where:
            v.script_id == ^mirror.id and is_nil(v.synced_at) and is_nil(v.peer_key) and
              v.kind in ^@pushed_version_kinds,
          order_by: [asc: v.id],
          preload: [:author]
        )
      )

    deletions =
      Repo.all(
        from(d in "peer_deletions",
          where: d.script_id == ^mirror.id,
          select: %{id: d.id, kind: d.kind, uid: d.uid}
        )
      )

    %{
      payload: %{
        comments: Enum.map(comments, &comment_payload/1),
        notes: Enum.map(notes, &note_payload/1),
        versions: Enum.map(versions, &version_payload/1),
        deletions: Enum.map(deletions, &Map.take(&1, [:kind, :uid]))
      },
      receipt: %{
        comments: Enum.map(comments, &{&1.id, &1.rev}),
        notes: Enum.map(notes, &{&1.id, &1.rev}),
        versions: Enum.map(versions, & &1.id),
        deletions: Enum.map(deletions, & &1.id)
      }
    }
  end

  def empty?(%{payload: p}) do
    p.comments == [] and p.notes == [] and p.versions == [] and p.deletions == []
  end

  @doc "After the origin accepted a push: everything unchanged since is now in sync."
  def mark_synced(%{receipt: receipt}) do
    for {id, rev} <- receipt.comments do
      from(c in Comment, where: c.id == ^id and c.rev == ^rev)
      |> Repo.update_all(set: [synced_rev: rev])
    end

    for {id, rev} <- receipt.notes do
      from(n in Note, where: n.id == ^id and n.rev == ^rev)
      |> Repo.update_all(set: [synced_rev: rev])
    end

    now = DateTime.utc_now(:second)
    from(v in Version, where: v.id in ^receipt.versions) |> Repo.update_all(set: [synced_at: now])
    from(d in "peer_deletions", where: d.id in ^receipt.deletions) |> Repo.delete_all()
    :ok
  end

  @doc "The highest origin version id this mirror holds; the next pull starts after it."
  def version_cursor(%Script{} = mirror) do
    Repo.one(from(v in Version, where: v.script_id == ^mirror.id, select: max(v.origin_id))) || 0
  end

  @doc """
  Applies the origin's activity to a mirror: upserts by uid, drops records
  the origin no longer has (never local work still waiting to be pushed),
  and leaves locally changed records alone until they have been pushed.
  """
  def apply_from_origin(%Script{} = mirror, data) when is_map(data) do
    key = mirror.origin_public_key
    # The first pull replays a whole history; nobody needs a notification per comment.
    first_pull? = is_nil(mirror.origin_activity_stamp)

    comment_items = list(data, "comments")

    comments? =
      Enum.reduce(comment_items, false, fn item, acc ->
        case find(Comment, mirror.id, item["uid"]) do
          nil ->
            case insert_comment(mirror, item, key, :mirror) do
              {:ok, comment} ->
                unless first_pull?, do: Scripts.notify_comment(mirror, comment, nil)
                true

              :skip ->
                acc
            end

          %Comment{} = existing ->
            if pending?(existing), do: acc, else: apply_resolution(existing, item, :mirror) or acc
        end
      end)

    note_items = list(data, "notes")

    notes? =
      Enum.reduce(note_items, false, fn item, acc ->
        case find(Note, mirror.id, item["uid"]) do
          nil ->
            insert_note(mirror, item, key, :mirror) == :ok or acc

          %Note{} = existing ->
            if pending?(existing),
              do: acc,
              else: apply_note_fields(existing, item, :mirror) or acc
        end
      end)

    comments_gone? = delete_missing(Comment, mirror.id, Enum.map(comment_items, & &1["uid"]))
    notes_gone? = delete_missing(Note, mirror.id, Enum.map(note_items, & &1["uid"]))

    now = DateTime.utc_now(:second)

    versions? =
      Enum.reduce(list(data, "versions"), false, fn item, acc ->
        case find(Version, mirror.id, item["uid"]) do
          nil ->
            insert_version(mirror, item, key, origin_id: item["id"], synced_at: now) == :ok or acc

          %Version{origin_id: nil} = own ->
            # One of ours, echoed back with the id it got at the origin.
            own |> Ecto.Changeset.change(origin_id: item["id"]) |> Repo.update!()
            acc

          %Version{} ->
            acc
        end
      end)

    {:ok, mirror} =
      mirror
      |> Ecto.Changeset.change(origin_activity_stamp: to_string(data["stamp"] || ""))
      |> Repo.update()

    announce(mirror, comments? or comments_gone?, notes? or notes_gone?, versions?)
    {:ok, mirror}
  end

  ## Records

  # On a mirror, records that arrive from the origin are in sync by definition.
  defp arrival_changes(:mirror), do: [rev: 1, synced_rev: 1]
  defp arrival_changes(:origin), do: []

  defp update_changes(%{rev: rev}, :mirror), do: [rev: rev + 1, synced_rev: rev + 1]
  defp update_changes(_record, :origin), do: []

  defp insert_comment(script, item, peer_key, side) do
    body = clip(item["body"], @max_body)

    parent_id =
      case item["parent_uid"] do
        nil ->
          nil

        parent_uid ->
          if parent = find(Comment, script.id, parent_uid), do: parent.id, else: :missing
      end

    if body == "" or parent_id == :missing or not is_binary(item["uid"]) do
      :skip
    else
      %Comment{
        script_id: script.id,
        uid: item["uid"],
        parent_id: parent_id,
        line_no: if(is_integer(item["line_no"]), do: item["line_no"]),
        anchor_text: clip(item["anchor_text"], 200),
        body: body,
        resolved_at: parse_time(item["resolved_at"]),
        remote_author: handle_from(item),
        peer_key: peer_key,
        inserted_at: parse_time(item["inserted_at"])
      }
      |> Ecto.Changeset.change(arrival_changes(side))
      |> Repo.insert(on_conflict: :nothing)
      |> case do
        {:ok, %Comment{id: id} = comment} when is_integer(id) -> {:ok, comment}
        _ -> :skip
      end
    end
  end

  defp apply_resolution(existing, item, side) do
    resolved_at = parse_time(item["resolved_at"])

    if same_time?(existing.resolved_at, resolved_at) do
      false
    else
      existing
      |> Ecto.Changeset.change([resolved_at: resolved_at] ++ update_changes(existing, side))
      |> Repo.update!()

      true
    end
  end

  defp insert_note(script, item, peer_key, side) do
    body = clip(item["body"], @max_body)

    if body == "" or not is_binary(item["uid"]) do
      :skip
    else
      %Note{
        script_id: script.id,
        uid: item["uid"],
        body: body,
        color: color(item["color"]),
        pinned: item["pinned"] == true,
        remote_author: handle_from(item),
        peer_key: peer_key,
        inserted_at: parse_time(item["inserted_at"])
      }
      |> Ecto.Changeset.change(arrival_changes(side))
      |> Repo.insert(on_conflict: :nothing)
      |> case do
        {:ok, %Note{id: id}} when is_integer(id) -> :ok
        _ -> :skip
      end
    end
  end

  defp apply_note_fields(existing, item, side) do
    fields = [
      body: clip(item["body"], @max_body),
      color: color(item["color"]),
      pinned: item["pinned"] == true
    ]

    if fields[:body] == "" or Enum.all?(fields, fn {k, v} -> Map.get(existing, k) == v end) do
      false
    else
      existing
      |> Ecto.Changeset.change(fields ++ update_changes(existing, side))
      |> Repo.update!()

      true
    end
  end

  defp insert_version(script, item, peer_key, extra) do
    if is_binary(item["uid"]) do
      %Version{
        script_id: script.id,
        uid: item["uid"],
        kind: if(item["kind"] in @version_kinds, do: item["kind"], else: "manual"),
        message: if(is_binary(item["message"]), do: clip(item["message"], 200)),
        content: to_string(item["content"] || ""),
        remote_author: handle_from(item),
        peer_key: peer_key,
        inserted_at: parse_time(item["inserted_at"])
      }
      |> Ecto.Changeset.change(extra)
      |> Repo.insert(on_conflict: :nothing)
      |> case do
        {:ok, %Version{id: id}} when is_integer(id) -> :ok
        _ -> :skip
      end
    else
      :skip
    end
  end

  defp delete_own(schema, script_id, uid, key) do
    case find(schema, script_id, uid) do
      %{peer_key: ^key} = record ->
        Repo.delete(record)
        true

      _ ->
        false
    end
  end

  # Records the origin no longer lists are gone; local work it never received stays.
  defp delete_missing(schema, script_id, uids) do
    {count, _} =
      from(r in schema,
        where: r.script_id == ^script_id and r.synced_rev > 0 and r.uid not in ^uids
      )
      |> Repo.delete_all()

    count > 0
  end

  defp announce(script, comments?, notes?, versions?) do
    if comments?, do: Scripts.broadcast(script.id, {:comments_changed, script.id})
    if notes?, do: Scripts.broadcast(script.id, {:notes_changed, script.id})
    if versions?, do: Scripts.broadcast(script.id, {:versions_changed, script.id})
    comments? or notes? or versions?
  end

  ## Payloads

  defp comment_payload(c) do
    %{
      uid: c.uid,
      parent_uid: c.parent && c.parent.uid,
      line_no: c.line_no,
      anchor_text: c.anchor_text,
      body: c.body,
      author: handle(c),
      resolved_at: iso(c.resolved_at),
      inserted_at: iso(c.inserted_at)
    }
  end

  defp note_payload(n) do
    %{
      uid: n.uid,
      body: n.body,
      color: n.color,
      pinned: n.pinned,
      author: handle(n),
      inserted_at: iso(n.inserted_at)
    }
  end

  defp version_payload(v) do
    %{
      id: v.id,
      uid: v.uid,
      message: v.message,
      kind: v.kind,
      content: v.content,
      author: handle(v),
      inserted_at: iso(v.inserted_at)
    }
  end

  @doc "Display name for a record's author: a peer handle or the local email's user part."
  def handle(%{remote_author: name}) when is_binary(name) and name != "", do: name

  def handle(%{author: %{email: email}}) when is_binary(email),
    do: email |> String.split("@") |> hd()

  def handle(_record), do: "someone"

  defp handle_from(item),
    do:
      clip(item["author"], 80)
      |> case(
        do: (
          "" -> "someone"
          name -> name
        )
      )

  ## Helpers

  defp find(schema, script_id, uid) when is_binary(uid),
    do: Repo.get_by(schema, script_id: script_id, uid: uid)

  defp find(_schema, _script_id, _uid), do: nil

  defp list(payload, key) do
    case payload[key] do
      items when is_list(items) -> Enum.filter(items, &is_map/1)
      _ -> []
    end
  end

  defp pending?(%{rev: rev, synced_rev: synced_rev}), do: rev > synced_rev

  defp same_time?(nil, nil), do: true
  defp same_time?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  defp same_time?(_a, _b), do: false

  defp color(value), do: if(value in Note.colors(), do: value, else: "yellow")

  defp clip(nil, _max), do: ""
  defp clip(value, max), do: value |> to_string() |> String.slice(0, max)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp stamp_part(nil), do: "-"
  defp stamp_part(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp stamp_part(other), do: to_string(other)
end
