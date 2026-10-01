defmodule Moorland.Repo.Migrations.RevisionSetSync do
  use Ecto.Migration

  # Revision sets travel between installations. Sets never change once
  # started, so like versions they carry synced_at (nil on a mirror = still
  # to push) rather than revision counters; ending revision mode deletes them.
  def up do
    alter table(:revision_sets) do
      add :uid, :string
      add :remote_author, :string
      add :peer_key, :binary
      add :synced_at, :utc_datetime
    end

    execute "UPDATE revision_sets SET uid = lower(hex(randomblob(16))) WHERE uid IS NULL"
    create unique_index(:revision_sets, [:script_id, :uid])
  end

  def down do
    drop index(:revision_sets, [:script_id, :uid])

    alter table(:revision_sets) do
      remove :uid
      remove :remote_author
      remove :peer_key
      remove :synced_at
    end
  end
end
