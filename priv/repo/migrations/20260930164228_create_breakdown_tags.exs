defmodule Moorland.Repo.Migrations.CreateBreakdownTags do
  use Ecto.Migration

  # Script breakdown: each row tags one production element (a prop, a
  # vehicle, a stunt...) at a spot in the script. The spot is the tagged text
  # plus the line it was on; the scene is worked out from the current text
  # every time, so tags follow their words as scenes are rewritten and moved.
  # An element is the set of tags sharing a category and name.
  #
  # uid / remote_author / peer_key / rev / synced_rev mirror comments and
  # notes, so tags can travel between installations the same way.
  def change do
    create table(:breakdown_tags) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :nilify_all)
      add :category, :string, null: false
      add :name, :string, null: false
      add :anchor_text, :string
      add :line_no, :integer, null: false, default: 0

      add :uid, :string, null: false
      add :remote_author, :string
      add :peer_key, :binary
      add :rev, :integer, null: false, default: 1
      add :synced_rev, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:breakdown_tags, [:script_id])
    create unique_index(:breakdown_tags, [:script_id, :uid])
  end
end
