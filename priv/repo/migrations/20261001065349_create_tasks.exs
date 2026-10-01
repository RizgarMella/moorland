defmodule Moorland.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  # The production calendar and task board. A task belongs to a phase (prep,
  # shoot, post), moves through todo/doing/done, may be assigned to a person
  # by name, and has a due date; given a start date too it is a span on the
  # calendar ("Prep", "Location scouting"). Synced like shots and tags.
  def change do
    create table(:tasks) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :nilify_all)
      add :title, :string, null: false
      add :phase, :string, null: false, default: "prep"
      add :status, :string, null: false, default: "todo"
      add :assignee, :string
      add :starts_on, :date
      add :due_on, :date

      add :uid, :string, null: false
      add :remote_author, :string
      add :peer_key, :binary
      add :rev, :integer, null: false, default: 1
      add :synced_rev, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:tasks, [:script_id])
    create unique_index(:tasks, [:script_id, :uid])
  end
end
