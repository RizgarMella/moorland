defmodule Moorland.Repo.Migrations.AddPeers do
  use Ecto.Migration

  def change do
    create table(:peer_identity) do
      add :name, :string, null: false, default: "My Moorland"
      add :public_key, :binary, null: false
      add :private_key, :binary, null: false
      add :host, :string, null: false, default: "127.0.0.1"
      add :port, :integer, null: false, default: 4000

      timestamps(type: :utc_datetime)
    end

    create table(:peers) do
      add :name, :string, null: false
      add :public_key, :binary, null: false
      add :host, :string, null: false
      add :port, :integer, null: false
      add :added_by_user_id, references(:users, on_delete: :delete_all), null: false
      add :last_seen_at, :utc_datetime
      add :last_error, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:peers, [:public_key])

    create table(:script_peer_shares) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :peer_id, references(:peers, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "editor"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:script_peer_shares, [:script_id, :peer_id])

    alter table(:scripts) do
      add :origin_public_key, :binary
      add :origin_script_id, :integer
      add :origin_version, :integer, null: false, default: 0
      add :origin_content, :text
      add :origin_role, :string
    end

    create index(:scripts, [:origin_public_key, :origin_script_id])
  end
end
