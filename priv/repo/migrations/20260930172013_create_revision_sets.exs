defmodule Moorland.Repo.Migrations.CreateRevisionSets do
  use Ecto.Migration

  # Revision mode: each set is a coloured round of changes to a locked
  # script (Blue, Pink, Yellow...). A set keeps the text as it stood when
  # the set began; the changed lines are the difference between that and
  # the text now, worked out as the writer types.
  def change do
    create table(:revision_sets) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :nilify_all)
      add :color, :string, null: false
      add :base_content, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create index(:revision_sets, [:script_id])
  end
end
