defmodule Moorland.Repo.Migrations.AddContentVersion do
  use Ecto.Migration

  def change do
    alter table(:scripts) do
      add :content_version, :integer, null: false, default: 0
    end
  end
end
