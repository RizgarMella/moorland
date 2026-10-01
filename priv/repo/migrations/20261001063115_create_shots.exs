defmodule Moorland.Repo.Migrations.CreateShots do
  use Ecto.Migration

  # Shot lists: each shot is anchored to words in the script, as breakdown
  # tags are, and its scene is found from the current text each time.
  # Within a scene shots run in `position` order and are numbered 12A, 12B.
  # uid / rev / synced_rev / peer_key / remote_author: peer sync, as tags.
  def change do
    create table(:shots) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :nilify_all)
      add :anchor_text, :string
      add :line_no, :integer, null: false, default: 0
      add :position, :integer, null: false, default: 0
      add :size, :string
      add :angle, :string
      add :movement, :string
      add :lens, :string
      add :description, :text, null: false, default: ""

      add :uid, :string, null: false
      add :remote_author, :string
      add :peer_key, :binary
      add :rev, :integer, null: false, default: 1
      add :synced_rev, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:shots, [:script_id])
    create unique_index(:shots, [:script_id, :uid])
  end
end
