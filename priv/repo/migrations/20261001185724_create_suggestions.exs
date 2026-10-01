defmodule Moorland.Repo.Migrations.CreateSuggestions do
  use Ecto.Migration

  # Suggested edits: proposed text plus a message, made against a known
  # content_version, sent by a peer (an AI assistant, say) that may comment
  # but not write. An editor applies one (through the usual three-way merge)
  # or dismisses it.
  def change do
    create table(:suggestions) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :uid, :string, null: false
      add :message, :string, null: false, default: ""
      add :content, :text, null: false
      add :base_version, :integer, null: false, default: 0
      add :status, :string, null: false, default: "open"
      add :remote_author, :string
      add :peer_key, :binary
      add :from_assistant, :boolean, null: false, default: false
      add :decided_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:suggestions, [:script_id, :status])
    create unique_index(:suggestions, [:script_id, :uid])
  end
end
