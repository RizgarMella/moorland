defmodule Moorland.Repo.Migrations.AddAssistantPeers do
  use Ecto.Migration

  # An AI assistant joins as an ordinary peer installation. Marking a peer as
  # an assistant badges what it writes; comments and notes carry the mark
  # themselves so it survives being relayed on to other mirrors.
  def change do
    alter table(:peers) do
      add :assistant, :boolean, null: false, default: false
    end

    alter table(:comments) do
      add :from_assistant, :boolean, null: false, default: false
    end

    alter table(:notes) do
      add :from_assistant, :boolean, null: false, default: false
    end
  end
end
