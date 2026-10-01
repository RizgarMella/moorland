defmodule Moorland.Repo.Migrations.AddScriptStages do
  use Ecto.Migration

  # The story-to-script pipeline: a work moves through stages (idea, short
  # story, story, script), each stage its own document, linked to the one it
  # grew from. Documents outside a pipeline have no stage.
  def change do
    alter table(:scripts) do
      add :stage, :string
      add :parent_script_id, references(:scripts, on_delete: :nilify_all)
    end

    create index(:scripts, [:parent_script_id])
  end
end
