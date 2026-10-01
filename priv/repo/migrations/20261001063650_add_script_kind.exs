defmodule Moorland.Repo.Migrations.AddScriptKind do
  use Ecto.Migration

  # A document is a screenplay (Fountain) or prose (Markdown): short stories
  # and books. Every existing script is a screenplay.
  def change do
    alter table(:scripts) do
      add :kind, :string, null: false, default: "screenplay"
    end
  end
end
