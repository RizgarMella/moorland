defmodule Moorland.Repo.Migrations.AddNoteKind do
  use Ecto.Migration

  # Idea sketches: half-formed premises, characters and scraps kept beside a
  # script. A sketch is a note of kind "sketch", so it syncs to peers like
  # any note. Every existing note stays a plain note.
  def change do
    alter table(:notes) do
      add :kind, :string, null: false, default: "note"
    end
  end
end
