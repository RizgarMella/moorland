defmodule Moorland.Repo.Migrations.CreateCallConfirmations do
  use Ecto.Migration

  # "Got it" on a call sheet: who confirmed which shoot day, and when. One
  # per person per day. Insert-only between installations, like versions:
  # synced_at nil on a mirror means the origin has not heard yet.
  def change do
    create table(:call_confirmations) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :day_uid, :string, null: false
      add :name, :string, null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :uid, :string, null: false
      add :peer_key, :binary
      add :synced_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:call_confirmations, [:script_id, :day_uid, :name])
    create unique_index(:call_confirmations, [:script_id, :uid])
  end
end
