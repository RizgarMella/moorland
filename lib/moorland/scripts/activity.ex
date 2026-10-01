defmodule Moorland.Scripts.Activity do
  @moduledoc """
  Comments, notes, breakdown tags and version history travelling between
  installations.

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

  Breakdown tags, shots and production tasks travel like notes (a peer may
  move anyone's task along the board, as it may resolve anyone's comment). An origin from before tags existed sends
  no `"tags"` list at all, and a mirror then leaves its tags alone rather
  than reading the silence as "all deleted".

  Revision sets are insert-only, like versions; an editor peer that ends
  revision mode deletes every set, wherever it was started.

  The stripboard travels as a whole board: the origin's replaces a mirror's
  on every pull, unless the mirror has changes of its own still to push;
  a mirror's push replaces the origin's (the last push wins, which suits a
  board kept by one person at a time).
  """

  import Ecto.Query, warn: false

  alias Moorland.Repo
  alias Moorland.Peers.Peer
  alias Moorland.Scripts

  alias Moorland.Scripts.{
    BreakdownTag,
    Comment,
    Note,
    ProductionTask,
    RevisionSet,
    ScheduleItem,
    Script,
    Shot,
    Version
  }

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

    {tag_count, tag_max} =
      Repo.one(
        from(t in BreakdownTag,
          where: t.script_id == ^script_id,
          select: {count(t.id), max(t.updated_at)}
        )
      )

    {shot_count, shot_max} =
      Repo.one(
        from(s in Shot,
          where: s.script_id == ^script_id,
          select: {count(s.id), max(s.updated_at)}
        )
      )

    {rev_count, rev_max} =
      Repo.one(
        from(r in RevisionSet,
          where: r.script_id == ^script_id,
          select: {count(r.id), max(r.id)}
        )
      )

    {task_count, task_max} =
      Repo.one(
        from(t in ProductionTask,
          where: t.script_id == ^script_id,
          select: {count(t.id), max(t.updated_at)}
        )
      )

    {item_count, item_max} =
      Repo.one(
        from(i in ScheduleItem,
          where: i.script_id == ^script_id,
          select: {count(i.id), max(i.updated_at)}
        )
      )

    version_max =
      Repo.one(from(v in Version, where: v.script_id == ^script_id, select: max(v.id)))

    "c#{comment_count}@#{stamp_part(comment_max)}|n#{note_count}@#{stamp_part(note_max)}" <>
      "|t#{tag_count}@#{stamp_part(tag_max)}|s#{item_count}@#{stamp_part(item_max)}" <>
      "|h#{shot_count}@#{stamp_part(shot_max)}|k#{task_count}@#{stamp_part(task_max)}" <>
      "|r#{rev_count}@#{stamp_part(rev_max)}" <>
      "|v#{version_max || 0}"
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

    tags =
      Repo.all(
        from(t in BreakdownTag,
          where: t.script_id == ^script.id,
          order_by: [asc: t.id],
          preload: [:author]
        )
      )

    %{
      stamp: stamp(script.id),
      comments: Enum.map(comments, &comment_payload/1),
      notes: Enum.map(notes, &note_payload/1),
      tags: Enum.map(tags, &tag_payload/1),
      shots: script.id |> all_shots() |> Enum.map(&shot_payload/1),
      tasks: script.id |> all_tasks() |> Enum.map(&task_payload/1),
      revision_sets: script.id |> all_revision_sets() |> Enum.map(&revision_payload/1),
      schedule: schedule_payload(script.id),
      versions: Enum.map(versions, &version_payload/1)
    }
  end

  @doc "Applies activity pushed by an editor peer. Broadcasts and nudges other peers on change."
  def apply_from_peer(%Peer{public_key: key} = peer, %Script{} = script, payload)
      when is_map(payload) do
    # What an assistant peer writes is marked as such, here and onwards.
    assistant? = peer.assistant == true

    comments? =
      Enum.reduce(list(payload, "comments"), false, fn item, acc ->
        case find(Comment, script.id, item["uid"]) do
          nil ->
            case insert_comment(script, item, key, :origin, assistant?) do
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
          nil -> insert_note(script, item, key, :origin, assistant?) == :ok or acc
          %Note{peer_key: ^key} = existing -> apply_note_fields(existing, item, :origin) or acc
          %Note{} -> acc
        end
      end)

    tags? =
      Enum.reduce(list(payload, "tags"), false, fn item, acc ->
        case find(BreakdownTag, script.id, item["uid"]) do
          nil ->
            insert_tag(script, item, key, :origin) == :ok or acc

          %BreakdownTag{peer_key: ^key} = existing ->
            apply_tag_fields(existing, item, :origin) or acc

          %BreakdownTag{} ->
            acc
        end
      end)

    shots? =
      Enum.reduce(list(payload, "shots"), false, fn item, acc ->
        case find(Shot, script.id, item["uid"]) do
          nil -> insert_shot(script, item, key, :origin) == :ok or acc
          %Shot{peer_key: ^key} = existing -> apply_shot_fields(existing, item, :origin) or acc
          %Shot{} -> acc
        end
      end)

    tasks? =
      Enum.reduce(list(payload, "tasks"), false, fn item, acc ->
        case find(ProductionTask, script.id, item["uid"]) do
          nil ->
            insert_task(script, item, key, :origin) == :ok or acc

          %ProductionTask{peer_key: ^key} = existing ->
            apply_task_fields(existing, item, :origin, :all) or acc

          %ProductionTask{} = existing ->
            apply_task_fields(existing, item, :origin, :status) or acc
        end
      end)

    revisions? =
      Enum.reduce(list(payload, "revision_sets"), false, fn item, acc ->
        if find(RevisionSet, script.id, item["uid"]) == nil,
          do: insert_revision_set(script, item, key, []) == :ok or acc,
          else: acc
      end)

    versions? =
      Enum.reduce(list(payload, "versions"), false, fn item, acc ->
        if item["kind"] in @pushed_version_kinds and find(Version, script.id, item["uid"]) == nil,
          do: insert_version(script, item, key, []) == :ok or acc,
          else: acc
      end)

    # Which kinds of record a peer's deletions removed.
    deleted =
      Enum.reduce(list(payload, "deletions"), MapSet.new(), fn item, deleted ->
        schema =
          case item["kind"] do
            "comment" -> Comment
            "note" -> Note
            "breakdown_tag" -> BreakdownTag
            "shot" -> Shot
            "task" -> ProductionTask
            _ -> nil
          end

        cond do
          item["kind"] == "revision_set" ->
            # Ending revision mode is the whole team's switch: any set goes.
            case find(RevisionSet, script.id, item["uid"]) do
              nil ->
                deleted

              set ->
                Repo.delete(set)
                MapSet.put(deleted, RevisionSet)
            end

          schema && delete_own(schema, script.id, item["uid"], key) ->
            MapSet.put(deleted, schema)

          true ->
            deleted
        end
      end)

    comments_deleted? = Comment in deleted
    notes_deleted? = Note in deleted
    tags_deleted? = BreakdownTag in deleted
    shots_deleted? = Shot in deleted
    tasks_deleted? = ProductionTask in deleted

    changed =
      announce(script, comments? or comments_deleted?, notes? or notes_deleted?, versions?)

    changed = announce_tags(script, tags? or tags_deleted?) or changed
    changed = announce_shots(script, shots? or shots_deleted?) or changed
    changed = announce_tasks(script, tasks? or tasks_deleted?) or changed
    changed = announce_revisions(script, revisions? or RevisionSet in deleted) or changed

    changed =
      case payload["schedule"] do
        items when is_list(items) ->
          announce_schedule(script, replace_schedule(script, items)) or changed

        _ ->
          changed
      end

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

    tags =
      Repo.all(
        from(t in BreakdownTag,
          where: t.script_id == ^mirror.id and t.rev > t.synced_rev,
          order_by: [asc: t.id],
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

    shots =
      Repo.all(
        from(s in Shot,
          where: s.script_id == ^mirror.id and s.rev > s.synced_rev,
          order_by: [asc: s.id],
          preload: [:author]
        )
      )

    tasks =
      Repo.all(
        from(t in ProductionTask,
          where: t.script_id == ^mirror.id and t.rev > t.synced_rev,
          order_by: [asc: t.id],
          preload: [:author]
        )
      )

    revision_sets =
      Repo.all(
        from(r in RevisionSet,
          where: r.script_id == ^mirror.id and is_nil(r.synced_at) and is_nil(r.peer_key),
          order_by: [asc: r.id],
          preload: [:author]
        )
      )

    schedule_rev = pending_schedule_rev(mirror.id)

    %{
      payload: %{
        comments: Enum.map(comments, &comment_payload/1),
        notes: Enum.map(notes, &note_payload/1),
        tags: Enum.map(tags, &tag_payload/1),
        shots: Enum.map(shots, &shot_payload/1),
        tasks: Enum.map(tasks, &task_payload/1),
        revision_sets: Enum.map(revision_sets, &revision_payload/1),
        schedule: if(schedule_rev, do: schedule_payload(mirror.id)),
        versions: Enum.map(versions, &version_payload/1),
        deletions: Enum.map(deletions, &Map.take(&1, [:kind, :uid]))
      },
      receipt: %{
        comments: Enum.map(comments, &{&1.id, &1.rev}),
        notes: Enum.map(notes, &{&1.id, &1.rev}),
        tags: Enum.map(tags, &{&1.id, &1.rev}),
        shots: Enum.map(shots, &{&1.id, &1.rev}),
        tasks: Enum.map(tasks, &{&1.id, &1.rev}),
        revision_sets: Enum.map(revision_sets, & &1.id),
        schedule: if(schedule_rev, do: {mirror.id, schedule_rev}),
        versions: Enum.map(versions, & &1.id),
        deletions: Enum.map(deletions, & &1.id)
      }
    }
  end

  def empty?(%{payload: p}) do
    p.comments == [] and p.notes == [] and p.tags == [] and p.shots == [] and p.tasks == [] and
      p.revision_sets == [] and p.schedule == nil and
      p.versions == [] and p.deletions == []
  end

  # The mirror's board revision if it has changes the origin hasn't had.
  defp pending_schedule_rev(script_id) do
    case Repo.one(
           from(s in Script,
             where: s.id == ^script_id,
             select: {s.schedule_rev, s.schedule_synced_rev}
           )
         ) do
      {rev, synced} when rev > synced -> rev
      _ -> nil
    end
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

    for {id, rev} <- Map.get(receipt, :tags, []) do
      from(t in BreakdownTag, where: t.id == ^id and t.rev == ^rev)
      |> Repo.update_all(set: [synced_rev: rev])
    end

    revision_ids = Map.get(receipt, :revision_sets, [])

    from(r in RevisionSet, where: r.id in ^revision_ids)
    |> Repo.update_all(set: [synced_at: DateTime.utc_now(:second)])

    for {id, rev} <- Map.get(receipt, :tasks, []) do
      from(t in ProductionTask, where: t.id == ^id and t.rev == ^rev)
      |> Repo.update_all(set: [synced_rev: rev])
    end

    for {id, rev} <- Map.get(receipt, :shots, []) do
      from(s in Shot, where: s.id == ^id and s.rev == ^rev)
      |> Repo.update_all(set: [synced_rev: rev])
    end

    with {script_id, rev} <- Map.get(receipt, :schedule) do
      from(s in Script, where: s.id == ^script_id)
      |> Repo.update_all(set: [schedule_synced_rev: rev])
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
            case insert_comment(mirror, item, key, :mirror, item["assistant"] == true) do
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
            insert_note(mirror, item, key, :mirror, item["assistant"] == true) == :ok or acc

          %Note{} = existing ->
            if pending?(existing),
              do: acc,
              else: apply_note_fields(existing, item, :mirror) or acc
        end
      end)

    comments_gone? = delete_missing(Comment, mirror.id, Enum.map(comment_items, & &1["uid"]))
    notes_gone? = delete_missing(Note, mirror.id, Enum.map(note_items, & &1["uid"]))

    tags? =
      if is_list(data["tags"]) do
        tag_items = list(data, "tags")

        changed? =
          Enum.reduce(tag_items, false, fn item, acc ->
            case find(BreakdownTag, mirror.id, item["uid"]) do
              nil ->
                insert_tag(mirror, item, key, :mirror) == :ok or acc

              %BreakdownTag{} = existing ->
                if pending?(existing),
                  do: acc,
                  else: apply_tag_fields(existing, item, :mirror) or acc
            end
          end)

        delete_missing(BreakdownTag, mirror.id, Enum.map(tag_items, & &1["uid"])) or changed?
      else
        false
      end

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

    shots? =
      if is_list(data["shots"]) do
        shot_items = list(data, "shots")

        changed? =
          Enum.reduce(shot_items, false, fn item, acc ->
            case find(Shot, mirror.id, item["uid"]) do
              nil ->
                insert_shot(mirror, item, key, :mirror) == :ok or acc

              %Shot{} = existing ->
                if pending?(existing),
                  do: acc,
                  else: apply_shot_fields(existing, item, :mirror) or acc
            end
          end)

        delete_missing(Shot, mirror.id, Enum.map(shot_items, & &1["uid"])) or changed?
      else
        false
      end

    tasks? =
      if is_list(data["tasks"]) do
        task_items = list(data, "tasks")

        changed? =
          Enum.reduce(task_items, false, fn item, acc ->
            case find(ProductionTask, mirror.id, item["uid"]) do
              nil ->
                insert_task(mirror, item, key, :mirror) == :ok or acc

              %ProductionTask{} = existing ->
                if pending?(existing),
                  do: acc,
                  else: apply_task_fields(existing, item, :mirror, :all) or acc
            end
          end)

        delete_missing(ProductionTask, mirror.id, Enum.map(task_items, & &1["uid"])) or changed?
      else
        false
      end

    revisions? =
      if is_list(data["revision_sets"]) do
        items = list(data, "revision_sets")
        now = DateTime.utc_now(:second)

        added =
          Enum.reduce(items, false, fn item, acc ->
            if find(RevisionSet, mirror.id, item["uid"]) == nil,
              do: insert_revision_set(mirror, item, key, synced_at: now) == :ok or acc,
              else: acc
          end)

        uids = items |> Enum.map(& &1["uid"]) |> Enum.filter(&is_binary/1)

        {gone, _} =
          from(r in RevisionSet,
            where: r.script_id == ^mirror.id and not is_nil(r.synced_at) and r.uid not in ^uids
          )
          |> Repo.delete_all()

        added or gone > 0
      else
        false
      end

    schedule? =
      with items when is_list(items) <- data["schedule"],
           nil <- pending_schedule_rev(mirror.id) do
        replace_schedule(mirror, items)
      else
        _ -> false
      end

    {:ok, mirror} =
      mirror
      |> Ecto.Changeset.change(origin_activity_stamp: to_string(data["stamp"] || ""))
      |> Repo.update()

    announce(mirror, comments? or comments_gone?, notes? or notes_gone?, versions?)
    announce_tags(mirror, tags?)
    announce_schedule(mirror, schedule?)
    announce_shots(mirror, shots?)
    announce_tasks(mirror, tasks?)
    announce_revisions(mirror, revisions?)
    {:ok, mirror}
  end

  ## Records

  # On a mirror, records that arrive from the origin are in sync by definition.
  defp arrival_changes(:mirror), do: [rev: 1, synced_rev: 1]
  defp arrival_changes(:origin), do: []

  defp update_changes(%{rev: rev}, :mirror), do: [rev: rev + 1, synced_rev: rev + 1]
  defp update_changes(_record, :origin), do: []

  defp insert_comment(script, item, peer_key, side, assistant?) do
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
        from_assistant: assistant?,
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

  defp insert_note(script, item, peer_key, side, assistant?) do
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
        kind: if(item["kind"] in Note.kinds(), do: item["kind"], else: "note"),
        from_assistant: assistant?,
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
      pinned: item["pinned"] == true,
      # A peer from before sketches sends no kind; keep what the note is.
      kind: if(item["kind"] in Note.kinds(), do: item["kind"], else: existing.kind)
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

  defp insert_tag(script, item, peer_key, side) do
    fields = tag_fields(item)

    if fields[:name] == "" or fields[:category] == nil or not is_binary(item["uid"]) do
      :skip
    else
      %BreakdownTag{
        script_id: script.id,
        uid: item["uid"],
        remote_author: handle_from(item),
        peer_key: peer_key,
        inserted_at: parse_time(item["inserted_at"])
      }
      |> Ecto.Changeset.change(fields ++ arrival_changes(side))
      |> Repo.insert(on_conflict: :nothing)
      |> case do
        {:ok, %BreakdownTag{id: id}} when is_integer(id) -> :ok
        _ -> :skip
      end
    end
  end

  defp apply_tag_fields(existing, item, side) do
    fields = tag_fields(item)

    if fields[:name] == "" or fields[:category] == nil or
         Enum.all?(fields, fn {k, v} -> Map.get(existing, k) == v end) do
      false
    else
      existing
      |> Ecto.Changeset.change(fields ++ update_changes(existing, side))
      |> Repo.update!()

      true
    end
  end

  defp tag_fields(item) do
    anchor = clip(item["anchor_text"], 200)

    [
      category: if(item["category"] in BreakdownTag.category_keys(), do: item["category"]),
      name: item["name"] |> clip(120) |> String.trim(),
      anchor_text: if(anchor == "", do: nil, else: anchor),
      line_no:
        if(is_integer(item["line_no"]) and item["line_no"] >= 0, do: item["line_no"], else: 0)
    ]
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

  # Makes the script's board exactly `items`, in order: matching by uid,
  # updating what changed, adding what is new and dropping what is gone.
  # Items that fail the same checks as a local edit are skipped.
  defp replace_schedule(script, items) do
    existing = Repo.all(from(i in ScheduleItem, where: i.script_id == ^script.id))
    by_uid = Map.new(existing, &{&1.uid, &1})

    changesets =
      items
      |> Enum.filter(&(is_map(&1) and is_binary(&1["uid"]) and &1["uid"] != ""))
      |> Enum.uniq_by(& &1["uid"])
      |> Enum.take(2_000)
      |> Enum.with_index()
      |> Enum.map(fn {item, position} ->
        record =
          Map.get(by_uid, item["uid"], %ScheduleItem{script_id: script.id, uid: item["uid"]})

        schedule_changeset(record, item, position)
      end)
      |> Enum.filter(&(&1 && &1.valid?))

    kept = MapSet.new(changesets, &Ecto.Changeset.get_field(&1, :uid))
    gone = Enum.reject(existing, &MapSet.member?(kept, &1.uid))
    changed = Enum.filter(changesets, &(&1.data.id == nil or &1.changes != %{}))

    Repo.transaction(fn ->
      Enum.each(gone, &Repo.delete!/1)
      Enum.each(changed, &Repo.insert_or_update!/1)
    end)

    gone != [] or changed != []
  end

  defp schedule_changeset(record, %{"kind" => "scene"} = item, position) do
    ScheduleItem.scene_changeset(record, %{
      heading: clip(item["heading"], 200),
      line_no:
        if(is_integer(item["line_no"]) and item["line_no"] >= 0, do: item["line_no"], else: 0),
      position: position
    })
  end

  defp schedule_changeset(record, %{"kind" => "day"} = item, position) do
    ScheduleItem.day_changeset(record, %{
      "position" => position,
      "shoot_date" => item["shoot_date"],
      "note" => item["note"],
      "crew_call" => item["crew_call"],
      "shooting_call" => item["shooting_call"],
      "location" => item["location"],
      "cast_calls" => if(is_map(item["cast_calls"]), do: item["cast_calls"], else: %{})
    })
  end

  defp schedule_changeset(_record, _item, _position), do: nil

  defp insert_shot(script, item, peer_key, side) do
    if is_binary(item["uid"]) do
      %Shot{
        script_id: script.id,
        uid: item["uid"],
        remote_author: handle_from(item),
        peer_key: peer_key,
        inserted_at: parse_time(item["inserted_at"])
      }
      |> Shot.changeset(shot_attrs(item))
      |> Ecto.Changeset.change(arrival_changes(side))
      |> then(&if(&1.valid?, do: Repo.insert(&1, on_conflict: :nothing), else: :skip))
      |> case do
        {:ok, %Shot{id: id}} when is_integer(id) -> :ok
        _ -> :skip
      end
    else
      :skip
    end
  end

  defp apply_shot_fields(existing, item, side) do
    changeset = Shot.changeset(existing, shot_attrs(item))

    if changeset.valid? and changeset.changes != %{} do
      changeset |> Ecto.Changeset.change(update_changes(existing, side)) |> Repo.update!()
      true
    else
      false
    end
  end

  # Incoming shots go through the same checks as a local one.
  defp shot_attrs(item) do
    %{
      "anchor_text" => clip(item["anchor_text"], 200),
      "line_no" =>
        if(is_integer(item["line_no"]) and item["line_no"] >= 0, do: item["line_no"], else: 0),
      "position" => if(is_integer(item["position"]), do: item["position"], else: 0),
      "size" => item["size"],
      "angle" => item["angle"],
      "movement" => item["movement"],
      "lens" => if(is_binary(item["lens"]), do: item["lens"]),
      "description" => clip(item["description"], 2000)
    }
  end

  defp insert_task(script, item, peer_key, side) do
    if is_binary(item["uid"]) do
      %ProductionTask{
        script_id: script.id,
        uid: item["uid"],
        remote_author: handle_from(item),
        peer_key: peer_key,
        inserted_at: parse_time(item["inserted_at"])
      }
      |> ProductionTask.changeset(task_attrs(item))
      |> Ecto.Changeset.change(arrival_changes(side))
      |> then(&if(&1.valid?, do: Repo.insert(&1, on_conflict: :nothing), else: :skip))
      |> case do
        {:ok, %ProductionTask{id: id}} when is_integer(id) -> :ok
        _ -> :skip
      end
    else
      :skip
    end
  end

  # `:status` takes only the board column: what a peer may change on
  # someone else's task.
  defp apply_task_fields(existing, item, side, which) do
    attrs =
      if which == :status, do: Map.take(task_attrs(item), ["status"]), else: task_attrs(item)

    changeset = ProductionTask.changeset(existing, attrs)

    if changeset.valid? and changeset.changes != %{} do
      changeset |> Ecto.Changeset.change(update_changes(existing, side)) |> Repo.update!()
      true
    else
      false
    end
  end

  defp task_attrs(item) do
    %{
      "title" => clip(item["title"], 200),
      "phase" => item["phase"],
      "status" => item["status"],
      "assignee" => if(is_binary(item["assignee"]), do: clip(item["assignee"], 80)),
      "starts_on" => item["starts_on"],
      "due_on" => item["due_on"]
    }
  end

  defp insert_revision_set(script, item, peer_key, extra) do
    color = clip(item["color"], 40)

    if is_binary(item["uid"]) and color != "" do
      %RevisionSet{
        script_id: script.id,
        uid: item["uid"],
        color: color,
        base_content: to_string(item["base_content"] || ""),
        remote_author: handle_from(item),
        peer_key: peer_key,
        inserted_at: parse_time(item["inserted_at"])
      }
      |> Ecto.Changeset.change(extra)
      |> Repo.insert(on_conflict: :nothing)
      |> case do
        {:ok, %RevisionSet{id: id}} when is_integer(id) -> :ok
        _ -> :skip
      end
    else
      :skip
    end
  end

  defp all_revision_sets(script_id) do
    Repo.all(
      from(r in RevisionSet,
        where: r.script_id == ^script_id,
        order_by: [asc: r.id],
        preload: [:author]
      )
    )
  end

  defp announce_revisions(script, true) do
    Scripts.broadcast(script.id, {:revisions_changed, script.id})
    true
  end

  defp announce_revisions(_script, false), do: false

  defp all_tasks(script_id) do
    Repo.all(
      from(t in ProductionTask,
        where: t.script_id == ^script_id,
        order_by: [asc: t.id],
        preload: [:author]
      )
    )
  end

  defp announce_tasks(script, true) do
    Scripts.broadcast(script.id, {:tasks_changed, script.id})
    true
  end

  defp announce_tasks(_script, false), do: false

  defp all_shots(script_id) do
    Repo.all(
      from(s in Shot, where: s.script_id == ^script_id, order_by: [asc: s.id], preload: [:author])
    )
  end

  defp announce_shots(script, true) do
    Scripts.broadcast(script.id, {:shots_changed, script.id})
    true
  end

  defp announce_shots(_script, false), do: false

  defp announce_schedule(script, true) do
    Scripts.broadcast(script.id, {:schedule_changed, script.id})
    true
  end

  defp announce_schedule(_script, false), do: false

  defp announce_tags(script, true) do
    Scripts.broadcast(script.id, {:breakdown_changed, script.id})
    true
  end

  defp announce_tags(_script, false), do: false

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
      assistant: c.from_assistant,
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
      kind: n.kind,
      author: handle(n),
      assistant: n.from_assistant,
      inserted_at: iso(n.inserted_at)
    }
  end

  defp schedule_payload(script_id) do
    from(i in ScheduleItem,
      where: i.script_id == ^script_id,
      order_by: [asc: i.position, asc: i.id]
    )
    |> Repo.all()
    |> Enum.map(fn i ->
      %{
        uid: i.uid,
        kind: i.kind,
        heading: i.heading,
        line_no: i.line_no,
        shoot_date: i.shoot_date && Date.to_iso8601(i.shoot_date),
        note: i.note,
        crew_call: i.crew_call,
        shooting_call: i.shooting_call,
        location: i.location,
        cast_calls: i.cast_calls
      }
    end)
  end

  defp revision_payload(r) do
    %{
      uid: r.uid,
      color: r.color,
      base_content: r.base_content,
      author: handle(r),
      inserted_at: iso(r.inserted_at)
    }
  end

  defp task_payload(t) do
    %{
      uid: t.uid,
      title: t.title,
      phase: t.phase,
      status: t.status,
      assignee: t.assignee,
      starts_on: t.starts_on && Date.to_iso8601(t.starts_on),
      due_on: t.due_on && Date.to_iso8601(t.due_on),
      author: handle(t),
      inserted_at: iso(t.inserted_at)
    }
  end

  defp shot_payload(s) do
    %{
      uid: s.uid,
      anchor_text: s.anchor_text,
      line_no: s.line_no,
      position: s.position,
      size: s.size,
      angle: s.angle,
      movement: s.movement,
      lens: s.lens,
      description: s.description,
      author: handle(s),
      inserted_at: iso(s.inserted_at)
    }
  end

  defp tag_payload(t) do
    %{
      uid: t.uid,
      category: t.category,
      name: t.name,
      anchor_text: t.anchor_text,
      line_no: t.line_no,
      author: handle(t),
      inserted_at: iso(t.inserted_at)
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
