defmodule Moorland.Scripts do
  @moduledoc """
  The Scripts context: screenplays, collaborators, versions, comments and notes.

  All functions take a `%Scope{}` as first argument and enforce the caller's
  role on the script (owner > editor > commenter > viewer).
  """

  import Ecto.Query, warn: false

  alias Moorland.Repo
  alias Moorland.Accounts.{Scope, User}
  alias Moorland.Peers.Peer

  alias Moorland.Scripts.{
    Script,
    Collaborator,
    Version,
    Comment,
    Note,
    Merge,
    ContentCache,
    PeerShare,
    CharacterMeta,
    Snippet,
    Notification,
    Activity
  }

  @auto_snapshot_interval_seconds 10 * 60

  ## PubSub

  def topic(script_id), do: "script:#{script_id}"

  def subscribe(script_id) do
    Phoenix.PubSub.subscribe(Moorland.PubSub, topic(script_id))
  end

  def broadcast(script_id, event) do
    Phoenix.PubSub.broadcast(Moorland.PubSub, topic(script_id), event)
  end

  ## Authorization

  @doc "Returns the caller's role on the script: :owner, :editor, :commenter, :viewer or nil."
  def role(%Scope{user: %User{id: user_id}}, %Script{} = script) do
    cond do
      script.owner_id == user_id ->
        :owner

      collab = Repo.get_by(Collaborator, script_id: script.id, user_id: user_id) ->
        String.to_existing_atom(collab.role)

      true ->
        nil
    end
  end

  def role(_scope, _script), do: nil

  def can_view?(role), do: role in [:owner, :editor, :commenter, :viewer]
  def can_comment?(role), do: role in [:owner, :editor, :commenter]
  def can_edit?(role), do: role in [:owner, :editor]
  def can_manage?(role), do: role == :owner

  ## Scripts

  @doc "All scripts the user owns or collaborates on, most recently updated first."
  def list_scripts(%Scope{user: %User{id: user_id}}) do
    from(s in Script,
      left_join: c in Collaborator,
      on: c.script_id == s.id and c.user_id == ^user_id,
      where: s.owner_id == ^user_id or not is_nil(c.id),
      order_by: [desc: s.updated_at],
      preload: [:owner]
    )
    |> Repo.all()
  end

  def get_script!(%Scope{} = scope, id) do
    script = Repo.get!(Script, id) |> Repo.preload(:owner)

    case role(scope, script) do
      nil -> raise Ecto.NoResultsError, queryable: Script
      role -> {script, effective_role(script, role)}
    end
  end

  # A mirror of a peer's script is edited under the role the origin granted,
  # even by its local owner - a viewer-role mirror is read-only.
  defp effective_role(%Script{origin_public_key: nil}, role), do: role

  defp effective_role(%Script{origin_role: "viewer"}, _role), do: :viewer
  defp effective_role(%Script{}, role) when role in [:owner, :editor], do: :editor
  defp effective_role(%Script{}, role), do: role

  def create_script(%Scope{user: %User{id: user_id}}, attrs) do
    %Script{owner_id: user_id}
    |> Script.changeset(attrs)
    |> Repo.insert()
    |> tap_mirror()
  end

  def update_script(%Scope{} = scope, %Script{} = script, attrs) do
    with :ok <- authorize(scope, script, :edit) do
      script
      |> Script.changeset(attrs)
      |> Repo.update()
      |> tap_mirror()
      |> tap_broadcast(scope, :script_updated)
    end
  end

  @doc """
  Saves new content coming from the editor.

  When `base_version` (the content_version the author's edits were built on)
  is behind the server, the incoming text is three-way merged against that
  base rather than clobbering concurrent edits. Saves for the same script are
  serialized so merge decisions never race. Also lays down an automatic
  snapshot when the last version is older than #{@auto_snapshot_interval_seconds} seconds.
  """
  def save_content(%Scope{user: user} = scope, %Script{} = script, content, base_version \\ nil)
      when is_binary(content) do
    with :ok <- authorize(scope, script, :edit) do
      with {:ok, saved} <- do_save_locked(script.id, content, base_version, user.id) do
        # The locked reload loses preloads; keep the caller's loaded owner.
        saved = %{saved | owner: script.owner}

        broadcast(
          script.id,
          {:content_saved, saved.id, user.id, saved.content, saved.content_version}
        )

        nudge_peers(saved)
        {:ok, saved}
      end
    end
  end

  # Push instead of poll: after a change, tell the other side to sync now.
  @doc false
  def nudge_peers(%Script{origin_public_key: nil} = script) do
    peers =
      from(sh in PeerShare,
        join: p in Peer,
        on: p.id == sh.peer_id,
        where: sh.script_id == ^script.id,
        select: p
      )
      |> Repo.all()

    if peers != [] do
      Task.start(fn -> Enum.each(peers, &Moorland.Peers.Client.notify/1) end)
    end

    :ok
  end

  # A local change to a mirror: push it to the origin right away.
  def nudge_peers(%Script{}) do
    Moorland.Peers.Sync.sync_now()
    :ok
  end

  defp do_save_locked(script_id, content, base_version, author_id) do
    result =
      ContentCache.locked(script_id, fn ->
        current = Repo.get!(Script, script_id)
        ContentCache.put(current.id, current.content_version, current.content)
        persist_version(current.id, current.content_version, current.content)

        merged =
          cond do
            base_version == nil or base_version == current.content_version ->
              content

            base =
                ContentCache.get(current.id, base_version) ||
                  stored_version_content(current.id, base_version) ->
              Merge.three_way(base, current.content, content)

            true ->
              # Base unknown even in the durable store: last write wins.
              content
          end

        current
        |> Script.content_changeset(%{content: merged})
        |> Ecto.Changeset.put_change(:content_version, current.content_version + 1)
        |> Repo.update()
      end)

    with {:ok, saved} <- result do
      ContentCache.put(saved.id, saved.content_version, saved.content)
      persist_version(saved.id, saved.content_version, saved.content)
      maybe_auto_snapshot(author_id, saved)
      Moorland.Storage.mirror_script(saved)
      {:ok, saved}
    end
  end

  # Durable merge bases: recent version contents survive restarts, so even a
  # very old tab still merges instead of clobbering.
  @kept_versions 200

  defp persist_version(script_id, version, content) do
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      "content_versions",
      [%{script_id: script_id, version: version, content: content, inserted_at: now}],
      on_conflict: :nothing
    )

    from(v in "content_versions",
      where: v.script_id == ^script_id and v.version < ^(version - @kept_versions)
    )
    |> Repo.delete_all()

    :ok
  end

  defp stored_version_content(script_id, version) do
    from(v in "content_versions",
      where: v.script_id == ^script_id and v.version == ^version,
      select: v.content
    )
    |> Repo.one()
  end

  ## Character metadata (gender tags for the reports' dialogue balance)

  @doc "Map of character name => gender for a script."
  def list_character_meta(%Script{} = script) do
    from(m in CharacterMeta, where: m.script_id == ^script.id, select: {m.name, m.gender})
    |> Repo.all()
    |> Map.new()
  end

  def set_character_gender(%Scope{} = scope, %Script{} = script, name, gender) do
    with :ok <- authorize(scope, script, :edit) do
      %CharacterMeta{}
      |> CharacterMeta.changeset(%{script_id: script.id, name: name, gender: gender})
      |> Repo.insert(
        on_conflict: {:replace, [:gender, :updated_at]},
        conflict_target: [:script_id, :name]
      )
      |> case do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  def delete_script(%Scope{} = scope, %Script{} = script) do
    with :ok <- authorize(scope, script, :manage),
         {:ok, deleted} <- Repo.delete(script) do
      Moorland.Storage.remove_mirror(deleted)
      {:ok, deleted}
    end
  end

  ## Collaborators

  def list_collaborators(%Script{} = script) do
    from(c in Collaborator,
      where: c.script_id == ^script.id,
      order_by: [asc: c.inserted_at],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc "Adds a collaborator by email. The user must already have an account."
  def add_collaborator(%Scope{} = scope, %Script{} = script, email, role_name) do
    with :ok <- authorize(scope, script, :manage) do
      case Repo.get_by(User, email: String.downcase(String.trim(email || ""))) do
        nil ->
          {:error, :user_not_found}

        %User{id: user_id} when user_id == script.owner_id ->
          {:error, :is_owner}

        %User{} = user ->
          %Collaborator{}
          |> Collaborator.changeset(%{script_id: script.id, user_id: user.id, role: role_name})
          |> Repo.insert()
          |> case do
            {:ok, collab} ->
              broadcast(script.id, {:collaborators_changed, script.id})
              {:ok, Repo.preload(collab, :user)}

            {:error, changeset} ->
              {:error, changeset}
          end
      end
    end
  end

  def update_collaborator_role(%Scope{} = scope, %Script{} = script, collab_id, role_name) do
    with :ok <- authorize(scope, script, :manage),
         %Collaborator{script_id: sid} = collab when sid == script.id <-
           Repo.get(Collaborator, collab_id) do
      collab
      |> Collaborator.changeset(%{role: role_name})
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          broadcast(script.id, {:collaborators_changed, script.id})
          {:ok, updated}

        error ->
          error
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def remove_collaborator(%Scope{} = scope, %Script{} = script, collab_id) do
    with :ok <- authorize(scope, script, :manage),
         %Collaborator{script_id: sid} = collab when sid == script.id <-
           Repo.get(Collaborator, collab_id) do
      Repo.delete(collab)
      broadcast(script.id, {:collaborators_changed, script.id})
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  ## Versions

  def list_versions(%Script{} = script) do
    from(v in Version,
      where: v.script_id == ^script.id,
      order_by: [desc: v.inserted_at, desc: v.id],
      preload: [:author]
    )
    |> Repo.all()
  end

  def get_version!(%Script{} = script, id) do
    Repo.get_by!(Version, id: id, script_id: script.id) |> Repo.preload(:author)
  end

  @doc "Creates a named snapshot of the script's current content."
  def create_snapshot(%Scope{user: user} = scope, %Script{} = script, message) do
    with :ok <- authorize(scope, script, :edit) do
      %Version{}
      |> Version.changeset(%{
        script_id: script.id,
        author_id: user.id,
        message: message,
        kind: "manual",
        content: script.content
      })
      |> Repo.insert()
      |> tap_broadcast_versions(script.id)
      |> tap_nudge(script)
    end
  end

  @doc """
  Restores the script to a version's content. The pre-restore content is
  itself snapshotted first, so a restore is never destructive.
  """
  def restore_version(%Scope{user: user} = scope, %Script{} = script, %Version{} = version) do
    with :ok <- authorize(scope, script, :edit) do
      Repo.transact(fn ->
        %Version{}
        |> Version.changeset(%{
          script_id: script.id,
          author_id: user.id,
          message: "Before restoring \"#{version.message || short_stamp(version)}\"",
          kind: "restore",
          content: script.content
        })
        |> Repo.insert!()

        script
        |> Script.content_changeset(%{content: version.content})
        |> Ecto.Changeset.put_change(:content_version, script.content_version + 1)
        |> Repo.update()
      end)
      |> case do
        {:ok, saved} ->
          ContentCache.put(saved.id, saved.content_version, saved.content)
          Moorland.Storage.mirror_script(saved)

          broadcast(
            script.id,
            {:content_saved, saved.id, user.id, saved.content, saved.content_version}
          )

          broadcast(script.id, {:versions_changed, script.id})
          nudge_peers(saved)
          {:ok, saved}

        error ->
          error
      end
    end
  end

  @doc "Line-by-line diff between two texts as a list of {:eq | :del | :ins, line} tuples."
  def diff_lines(old_text, new_text) do
    old_lines = String.split(old_text || "", "\n")
    new_lines = String.split(new_text || "", "\n")

    List.myers_difference(old_lines, new_lines)
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &{:eq, &1})
      {:del, lines} -> Enum.map(lines, &{:del, &1})
      {:ins, lines} -> Enum.map(lines, &{:ins, &1})
    end)
  end

  defp maybe_auto_snapshot(user_id, %Script{} = script) do
    last =
      from(v in Version,
        where: v.script_id == ^script.id,
        order_by: [desc: v.inserted_at, desc: v.id],
        limit: 1
      )
      |> Repo.one()

    stale? =
      case last do
        nil ->
          true

        %Version{} = v ->
          DateTime.diff(DateTime.utc_now(), v.inserted_at) > @auto_snapshot_interval_seconds and
            v.content != script.content
      end

    if stale? and script.content != "" do
      %Version{}
      |> Version.changeset(%{
        script_id: script.id,
        author_id: user_id,
        kind: "auto",
        content: script.content
      })
      |> Repo.insert()

      broadcast(script.id, {:versions_changed, script.id})
    end
  end

  ## Comments

  @doc "Top-level comment threads with replies, oldest first. Optionally hide resolved."
  def list_comments(%Script{} = script, opts \\ []) do
    include_resolved? = Keyword.get(opts, :include_resolved, true)

    query =
      from(c in Comment,
        where: c.script_id == ^script.id and is_nil(c.parent_id),
        order_by: [asc: c.inserted_at],
        preload: [:author, replies: [:author]]
      )

    query =
      if include_resolved?,
        do: query,
        else: from(c in query, where: is_nil(c.resolved_at))

    Repo.all(query)
  end

  def create_comment(%Scope{user: user} = scope, %Script{} = script, attrs) do
    with :ok <- authorize(scope, script, :comment) do
      %Comment{script_id: script.id, author_id: user.id}
      |> Comment.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, comment} ->
          broadcast(script.id, {:comments_changed, script.id})
          notify_comment(script, comment, user.id)
          nudge_peers(script)
          {:ok, Repo.preload(comment, :author)}

        error ->
          error
      end
    end
  end

  def resolve_comment(%Scope{} = scope, %Script{} = script, comment_id, resolved?) do
    with :ok <- authorize(scope, script, :comment),
         %Comment{script_id: sid} = comment when sid == script.id <-
           Repo.get(Comment, comment_id) do
      comment
      |> Ecto.Changeset.change(
        resolved_at: if(resolved?, do: DateTime.utc_now(:second), else: nil),
        rev: comment.rev + 1
      )
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          broadcast(script.id, {:comments_changed, script.id})
          nudge_peers(script)
          {:ok, updated}

        error ->
          error
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Authors can delete their own comments; the owner can delete any."
  def delete_comment(%Scope{user: user} = scope, %Script{} = script, comment_id) do
    with %Comment{script_id: sid} = comment when sid == script.id <-
           Repo.get(Comment, comment_id),
         true <- comment.author_id == user.id or role(scope, script) == :owner do
      Activity.remember_deletion(script, "comment", comment)
      Repo.delete(comment)
      broadcast(script.id, {:comments_changed, script.id})
      nudge_peers(script)
      :ok
    else
      _ -> {:error, :not_allowed}
    end
  end

  ## Notes

  def list_notes(%Script{} = script) do
    from(n in Note,
      where: n.script_id == ^script.id,
      order_by: [desc: n.pinned, desc: n.updated_at],
      preload: [:author]
    )
    |> Repo.all()
  end

  def create_note(%Scope{user: user} = scope, %Script{} = script, attrs) do
    with :ok <- authorize(scope, script, :comment) do
      %Note{script_id: script.id, author_id: user.id}
      |> Note.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, note} ->
          broadcast(script.id, {:notes_changed, script.id})
          nudge_peers(script)
          {:ok, Repo.preload(note, :author)}

        error ->
          error
      end
    end
  end

  def update_note(%Scope{user: user} = scope, %Script{} = script, note_id, attrs) do
    with %Note{script_id: sid} = note when sid == script.id <- Repo.get(Note, note_id),
         true <- note.author_id == user.id or role(scope, script) == :owner do
      note
      |> Note.changeset(attrs)
      |> Ecto.Changeset.put_change(:rev, note.rev + 1)
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          broadcast(script.id, {:notes_changed, script.id})
          nudge_peers(script)
          {:ok, updated}

        error ->
          error
      end
    else
      _ -> {:error, :not_allowed}
    end
  end

  def delete_note(%Scope{user: user} = scope, %Script{} = script, note_id) do
    with %Note{script_id: sid} = note when sid == script.id <- Repo.get(Note, note_id),
         true <- note.author_id == user.id or role(scope, script) == :owner do
      Activity.remember_deletion(script, "note", note)
      Repo.delete(note)
      broadcast(script.id, {:notes_changed, script.id})
      nudge_peers(script)
      :ok
    else
      _ -> {:error, :not_allowed}
    end
  end

  ## Peer sharing (origin side: this installation owns the script)

  @doc "Map of peer_id => role for a script's peer shares."
  def list_peer_shares(%Script{} = script) do
    from(sh in PeerShare, where: sh.script_id == ^script.id, select: {sh.peer_id, sh.role})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Sets, changes, or removes (role: nil/\"\") a peer share. Owner only."
  def set_peer_share(%Scope{} = scope, %Script{} = script, peer_id, role) do
    with :ok <- authorize(scope, script, :manage) do
      existing = Repo.get_by(PeerShare, script_id: script.id, peer_id: peer_id)

      case {existing, role} do
        {nil, r} when r in [nil, ""] ->
          :ok

        {%PeerShare{} = share, r} when r in [nil, ""] ->
          Repo.delete(share)
          :ok

        {nil, role} ->
          %PeerShare{}
          |> PeerShare.changeset(%{script_id: script.id, peer_id: peer_id, role: role})
          |> Repo.insert()
          |> normalize_share_result()

        {share, role} ->
          share
          |> PeerShare.changeset(%{role: role})
          |> Repo.update()
          |> normalize_share_result()
      end
    end
  end

  defp normalize_share_result({:ok, _}), do: :ok
  defp normalize_share_result(error), do: error

  defp peer_share_for(public_key, script_id) do
    from(sh in PeerShare,
      join: p in Peer,
      on: sh.peer_id == p.id,
      where: p.public_key == ^public_key and sh.script_id == ^script_id
    )
    |> Repo.one()
  end

  @doc "Scripts this installation shares with the requesting peer."
  def peer_list_shared(public_key) do
    from(sh in PeerShare,
      join: p in Peer,
      on: sh.peer_id == p.id,
      join: s in Script,
      on: s.id == sh.script_id,
      where: p.public_key == ^public_key,
      select: %{
        id: s.id,
        title: s.title,
        content_version: s.content_version,
        updated_at: s.updated_at,
        role: sh.role
      }
    )
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :activity, Activity.stamp(&1.id)))
  end

  def peer_fetch(public_key, script_id) do
    case peer_share_for(public_key, script_id) do
      %PeerShare{role: role} ->
        script = Repo.get!(Script, script_id)

        {:ok,
         %{
           id: script.id,
           title: script.title,
           content: script.content,
           content_version: script.content_version,
           role: role
         }}

      nil ->
        {:error, :not_shared}
    end
  end

  @doc """
  Accepts a save pushed by a peer. Merges against the peer's base version
  exactly like a local concurrent save, so peer edits and local edits weave
  together instead of clobbering.
  """
  def peer_save(public_key, script_id, content, base_version) when is_binary(content) do
    case peer_share_for(public_key, script_id) do
      %PeerShare{role: "editor"} ->
        with {:ok, saved} <- do_save_locked(script_id, content, base_version, nil) do
          broadcast(
            saved.id,
            {:content_saved, saved.id, nil, saved.content, saved.content_version}
          )

          {:ok, %{content: saved.content, content_version: saved.content_version}}
        end

      %PeerShare{} ->
        {:error, :read_only}

      nil ->
        {:error, :not_shared}
    end
  end

  @doc "Comments, notes and versions after `after_version_id` of a script shared with the peer."
  def peer_activity(public_key, script_id, after_version_id) do
    case peer_share_for(public_key, script_id) do
      %PeerShare{} -> {:ok, Activity.for_peer(Repo.get!(Script, script_id), after_version_id)}
      nil -> {:error, :not_shared}
    end
  end

  @doc "Applies comments, notes, snapshots and deletions pushed by an editor peer."
  def peer_apply_activity(public_key, script_id, payload) when is_map(payload) do
    case peer_share_for(public_key, script_id) do
      %PeerShare{role: "editor"} ->
        peer = Moorland.Peers.get_by_public_key(public_key)
        Activity.apply_from_peer(peer, Repo.get!(Script, script_id), payload)
        {:ok, %{ok: true}}

      %PeerShare{} ->
        {:error, :read_only}

      nil ->
        {:error, :not_shared}
    end
  end

  ## Peer mirrors (this installation holds a synced copy of a peer's script)

  def get_mirror(public_key, origin_script_id) do
    Repo.get_by(Script, origin_public_key: public_key, origin_script_id: origin_script_id)
  end

  def create_mirror(%Peer{} = peer, %{
        "id" => origin_id,
        "title" => title,
        "content" => content,
        "content_version" => version,
        "role" => role
      }) do
    %Script{
      owner_id: peer.added_by_user_id,
      origin_public_key: peer.public_key,
      origin_script_id: origin_id,
      origin_version: version,
      origin_content: content,
      origin_role: role,
      content: content
    }
    |> Script.changeset(%{title: title})
    |> Repo.insert()
    |> tap_mirror()
  end

  @doc "Applies content agreed with the origin (a pull, or a push's merge result)."
  def apply_origin_content(%Script{} = mirror, title, content, version, role \\ nil) do
    mirror
    |> Script.changeset(%{title: title, content: content})
    |> Ecto.Changeset.change(
      origin_version: version,
      origin_content: content,
      origin_role: role || mirror.origin_role,
      content_version: mirror.content_version + 1
    )
    |> Repo.update()
    |> case do
      {:ok, saved} ->
        ContentCache.put(saved.id, saved.content_version, saved.content)
        Moorland.Storage.mirror_script(saved)
        broadcast(saved.id, {:content_saved, saved.id, nil, saved.content, saved.content_version})
        {:ok, saved}

      error ->
        error
    end
  end

  ## Bin & Shelf (cut text that is never lost)

  @doc "The script's Bin: text cut out of this script, visible to its team."
  def list_bin(%Script{} = script) do
    from(s in Snippet,
      where: s.script_id == ^script.id,
      order_by: [desc: s.inserted_at],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc "The user's Shelf: cross-script snippets, private to them."
  def list_shelf(%Scope{user: user}) do
    from(s in Snippet,
      where: s.user_id == ^user.id and is_nil(s.script_id),
      order_by: [desc: s.inserted_at]
    )
    |> Repo.all()
  end

  def create_bin_snippet(%Scope{user: user} = scope, %Script{} = script, body) do
    with :ok <- authorize(scope, script, :edit) do
      %Snippet{user_id: user.id, script_id: script.id}
      |> Snippet.changeset(%{body: body})
      |> Repo.insert()
    end
  end

  def create_shelf_snippet(%Scope{user: user}, body) do
    %Snippet{user_id: user.id}
    |> Snippet.changeset(%{body: body})
    |> Repo.insert()
  end

  @doc "Moves a bin snippet to the caller's private shelf (author only)."
  def move_snippet_to_shelf(%Scope{user: user}, snippet_id) do
    case Repo.get(Snippet, snippet_id) do
      %Snippet{user_id: uid} = snippet when uid == user.id ->
        snippet |> Ecto.Changeset.change(script_id: nil) |> Repo.update()

      _ ->
        {:error, :not_allowed}
    end
  end

  def delete_snippet(%Scope{user: user} = scope, snippet_id) do
    case Repo.get(Snippet, snippet_id) do
      nil ->
        {:error, :not_found}

      %Snippet{user_id: uid} = snippet when uid == user.id ->
        Repo.delete(snippet)

      %Snippet{script_id: sid} = snippet when sid != nil ->
        script = Repo.get!(Script, sid)

        if role(scope, script) == :owner do
          Repo.delete(snippet)
        else
          {:error, :not_allowed}
        end

      _ ->
        {:error, :not_allowed}
    end
  end

  ## Search (scripts, comments and notes the user can access)

  def search(%Scope{user: %User{id: user_id}} = _scope, query) do
    q = String.trim(to_string(query))

    if String.length(q) < 2 do
      []
    else
      like = "%" <> String.replace(q, ~r/[%_\\]/, "") <> "%"

      accessible =
        from(s in Script,
          left_join: c in Collaborator,
          on: c.script_id == s.id and c.user_id == ^user_id,
          where: s.owner_id == ^user_id or not is_nil(c.id),
          select: s.id
        )

      scripts =
        from(s in Script,
          where: s.id in subquery(accessible),
          where: like(s.title, ^like) or like(s.content, ^like),
          limit: 10
        )
        |> Repo.all()
        |> Enum.map(fn s ->
          %{
            kind: :script,
            script_id: s.id,
            title: s.title,
            snippet: content_snippet(s, q)
          }
        end)

      comments =
        from(cm in Comment,
          join: s in Script,
          on: s.id == cm.script_id,
          where: cm.script_id in subquery(accessible) and like(cm.body, ^like),
          limit: 10,
          select: {s.id, s.title, cm.body}
        )
        |> Repo.all()
        |> Enum.map(fn {sid, title, body} ->
          %{kind: :comment, script_id: sid, title: title, snippet: around(body, q)}
        end)

      notes =
        from(n in Note,
          join: s in Script,
          on: s.id == n.script_id,
          where: n.script_id in subquery(accessible) and like(n.body, ^like),
          limit: 10,
          select: {s.id, s.title, n.body}
        )
        |> Repo.all()
        |> Enum.map(fn {sid, title, body} ->
          %{kind: :note, script_id: sid, title: title, snippet: around(body, q)}
        end)

      scripts ++ comments ++ notes
    end
  end

  defp content_snippet(%Script{} = s, q) do
    if String.contains?(String.downcase(s.content || ""), String.downcase(q)) do
      around(s.content, q)
    else
      "title match"
    end
  end

  defp around(text, q) do
    down = String.downcase(text)

    case :binary.match(down, String.downcase(q)) do
      {pos, _len} ->
        from = max(0, pos - 30)

        text
        |> binary_part(from, min(90, byte_size(text) - from))
        |> String.replace(~r/\s+/, " ")
        |> then(&if(from > 0, do: "…" <> &1, else: &1))

      :nomatch ->
        String.slice(text, 0, 80)
    end
  rescue
    # binary_part on a multi-byte boundary: fall back to a safe slice.
    _ -> String.slice(text, 0, 80)
  end

  ## Notifications (@mentions and comment activity)

  def unread_notifications(%Scope{user: user}) do
    from(n in Notification,
      where: n.user_id == ^user.id and is_nil(n.read_at),
      group_by: n.script_id,
      select: {n.script_id, count(n.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  def mark_notifications_read(%Scope{user: user}, %Script{} = script) do
    from(n in Notification,
      where: n.user_id == ^user.id and n.script_id == ^script.id and is_nil(n.read_at)
    )
    |> Repo.update_all(set: [read_at: DateTime.utc_now(:second)])

    Phoenix.PubSub.broadcast(Moorland.PubSub, "user:#{user.id}", :notifications_changed)
    :ok
  end

  # Called after a comment is created: everyone on the script hears about it;
  # anyone @mentioned (by the part of their email before the @) also gets mail.
  # `author_id` is nil for comments that arrived from a peer.
  @doc false
  def notify_comment(%Script{} = script, comment, author_id) do
    script = Repo.preload(script, collaborators: [:user], owner: [])
    members = [script.owner | Enum.map(script.collaborators, & &1.user)]

    mentioned =
      Regex.scan(~r/@([\w.+-]+)/, comment.body || "")
      |> Enum.map(fn [_, handle] -> String.downcase(handle) end)

    now = DateTime.utc_now(:second)

    rows =
      members
      |> Enum.uniq_by(& &1.id)
      |> Enum.reject(&(&1.id == author_id))
      |> Enum.map(fn member ->
        local = member.email |> String.downcase() |> String.split("@") |> hd()

        kind =
          if local in mentioned or String.downcase(member.email) in mentioned,
            do: "mention",
            else: "comment"

        %{
          user_id: member.id,
          script_id: script.id,
          comment_id: comment.id,
          kind: kind,
          body: String.slice(comment.body || "", 0, 120),
          inserted_at: now
        }
      end)

    Repo.insert_all(Notification, rows)

    for row <- rows do
      Phoenix.PubSub.broadcast(Moorland.PubSub, "user:#{row.user_id}", :notifications_changed)

      if row.kind == "mention" do
        member = Enum.find(members, &(&1.id == row.user_id))
        Moorland.Scripts.MentionNotifier.deliver(member, script, comment)
      end
    end

    :ok
  end

  ## Helpers

  defp authorize(scope, script, action) do
    r = role(scope, script)

    allowed? =
      case action do
        :view -> can_view?(r)
        :comment -> can_comment?(r)
        :edit -> can_edit?(r)
        :manage -> can_manage?(r)
      end

    if allowed?, do: :ok, else: {:error, :not_allowed}
  end

  defp tap_mirror({:ok, %Script{} = script} = result) do
    Moorland.Storage.mirror_script(script)
    result
  end

  defp tap_mirror(result), do: result

  defp tap_broadcast({:ok, %Script{} = script} = result, _scope, event_name) do
    broadcast(script.id, {event_name, script.id})
    result
  end

  defp tap_broadcast(result, _scope, _event), do: result

  defp tap_broadcast_versions({:ok, _} = result, script_id) do
    broadcast(script_id, {:versions_changed, script_id})
    result
  end

  defp tap_broadcast_versions(result, _script_id), do: result

  defp tap_nudge({:ok, _} = result, script) do
    nudge_peers(script)
    result
  end

  defp tap_nudge(result, _script), do: result

  defp short_stamp(%Version{inserted_at: at}), do: Calendar.strftime(at, "%b %d %H:%M")
end
