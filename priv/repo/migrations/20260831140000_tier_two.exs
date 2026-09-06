defmodule Moorland.Repo.Migrations.TierTwo do
  use Ecto.Migration

  def change do
    # Bin (per-script cut text) & Shelf (cross-script, per-user snippets).
    create table(:snippets) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :script_id, references(:scripts, on_delete: :delete_all)
      add :body, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:snippets, [:script_id])
    create index(:snippets, [:user_id])

    # Comment / mention notifications with unread tracking.
    create table(:notifications) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :comment_id, references(:comments, on_delete: :delete_all)
      add :kind, :string, null: false, default: "comment"
      add :body, :string
      add :read_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:notifications, [:user_id, :read_at])
    create index(:notifications, [:script_id])

    # Production rolodex (feeds call sheets & DOOD later).
    create table(:contacts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :role, :string
      add :department, :string
      add :email, :string
      add :phone, :string
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:contacts, [:user_id])
  end
end
