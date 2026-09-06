defmodule Moorland.Repo.Migrations.TierThreeActivity do
  use Ecto.Migration

  # Comments, notes and version history now travel between installations.
  # A record that arrived from a peer has no local author, so author_id
  # becomes nullable on comments and notes. SQLite cannot change a column's
  # constraints, so those two tables are rebuilt in place, ids preserved.
  #
  # New columns on comments, notes and script_versions:
  #   uid           - unique within a script, what peers key on
  #   remote_author - display handle when the author lives on another install
  #   peer_key      - which peer the record arrived from (nil = local)
  # Comments and notes also get rev / synced_rev: a local edit bumps rev, a
  # push to the origin records it in synced_rev, and the two differing means
  # "still to push". Versions never change, so they carry synced_at instead.
  # Existing rows start at rev 1 / synced_rev 0: a mirror's pre-existing local
  # comments are pushed to their origin on the first sync.

  def up do
    rebuild_comments()
    rebuild_notes()

    alter table(:script_versions) do
      add :uid, :string
      add :remote_author, :string
      add :peer_key, :binary
      add :origin_id, :integer
      add :synced_at, :utc_datetime
    end

    execute "UPDATE script_versions SET uid = lower(hex(randomblob(16))) WHERE uid IS NULL"
    create unique_index(:script_versions, [:script_id, :uid])

    alter table(:scripts) do
      add :origin_activity_stamp, :string
    end

    # Deletions a mirror still has to tell its origin about.
    create table(:peer_deletions) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :uid, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:peer_deletions, [:script_id])
  end

  def down do
    raise "irreversible: comments and notes were rebuilt with nullable authors"
  end

  defp rebuild_comments do
    # Notifications point at comments; park those links while the table is
    # rebuilt so dropping it does not cascade into them.
    execute """
    CREATE TEMP TABLE notification_comments AS
    SELECT id, comment_id FROM notifications WHERE comment_id IS NOT NULL
    """

    execute "UPDATE notifications SET comment_id = NULL"

    create table(:comments_new) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :delete_all)
      add :parent_id, references(:comments_new, on_delete: :delete_all)
      add :line_no, :integer
      add :anchor_text, :string
      add :body, :text, null: false
      add :resolved_at, :utc_datetime
      add :uid, :string, null: false
      add :remote_author, :string
      add :peer_key, :binary
      add :rev, :integer, null: false, default: 1
      add :synced_rev, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    execute """
    INSERT INTO comments_new
      (id, script_id, author_id, parent_id, line_no, anchor_text, body, resolved_at,
       uid, inserted_at, updated_at)
    SELECT id, script_id, author_id, parent_id, line_no, anchor_text, body, resolved_at,
           lower(hex(randomblob(16))), inserted_at, updated_at
    FROM comments
    """

    drop table(:comments)
    rename table(:comments_new), to: table(:comments)
    create index(:comments, [:script_id])
    create index(:comments, [:parent_id])
    create unique_index(:comments, [:script_id, :uid])

    execute """
    UPDATE notifications
    SET comment_id = (SELECT comment_id FROM notification_comments nc WHERE nc.id = notifications.id)
    WHERE id IN (SELECT id FROM notification_comments)
    """

    execute "DROP TABLE notification_comments"
  end

  defp rebuild_notes do
    create table(:notes_new) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :delete_all)
      add :body, :text, null: false
      add :color, :string, null: false, default: "yellow"
      add :pinned, :boolean, null: false, default: false
      add :uid, :string, null: false
      add :remote_author, :string
      add :peer_key, :binary
      add :rev, :integer, null: false, default: 1
      add :synced_rev, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    execute """
    INSERT INTO notes_new
      (id, script_id, author_id, body, color, pinned, uid, inserted_at, updated_at)
    SELECT id, script_id, author_id, body, color, pinned,
           lower(hex(randomblob(16))), inserted_at, updated_at
    FROM notes
    """

    drop table(:notes)
    rename table(:notes_new), to: table(:notes)
    create index(:notes, [:script_id])
    create unique_index(:notes, [:script_id, :uid])
  end
end
