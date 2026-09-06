defmodule Moorland.Repo.Migrations.TierOne do
  use Ecto.Migration

  def change do
    alter table(:scripts) do
      add :goal_words, :integer
      add :goal_pages, :integer
    end

    # Gender tags for speaking parts (reports' dialogue-balance analysis).
    create table(:character_meta) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :gender, :string, null: false, default: "unspecified"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:character_meta, [:script_id, :name])

    # Durable merge bases: old editor tabs merge instead of last-write-wins.
    create table(:content_versions) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :version, :integer, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:content_versions, [:script_id, :version])
  end
end
