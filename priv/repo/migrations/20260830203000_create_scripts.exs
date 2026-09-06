defmodule Moorland.Repo.Migrations.CreateScripts do
  use Ecto.Migration

  def change do
    create table(:scripts) do
      add :title, :string, null: false
      add :content, :text, null: false, default: ""
      add :owner_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:scripts, [:owner_id])

    create table(:script_collaborators) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "editor"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:script_collaborators, [:script_id, :user_id])
    create index(:script_collaborators, [:user_id])

    create table(:script_versions) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :nilify_all)
      add :message, :string
      add :kind, :string, null: false, default: "manual"
      add :content, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:script_versions, [:script_id])

    create table(:comments) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :delete_all), null: false
      add :parent_id, references(:comments, on_delete: :delete_all)
      add :line_no, :integer
      add :anchor_text, :string
      add :body, :text, null: false
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:comments, [:script_id])
    create index(:comments, [:parent_id])

    create table(:notes) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :delete_all), null: false
      add :body, :text, null: false
      add :color, :string, null: false, default: "yellow"
      add :pinned, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:notes, [:script_id])
  end
end
