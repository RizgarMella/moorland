defmodule Moorland.Repo.Migrations.CreateMediaItems do
  use Ecto.Migration

  # The media library: reference files for a production (images, PDFs,
  # audio, video) kept in the data folder's media/<script id>/ under a
  # name unique per upload (`file`). `board` names the mood board an item
  # is pinned to; empty means the library only.
  # uid / rev / synced_rev / peer_key / remote_author: peer sync, as shots.
  def change do
    create table(:media_items) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :nilify_all)
      add :file, :string
      add :filename, :string, null: false, default: ""
      add :title, :string, null: false, default: ""
      add :caption, :text, null: false, default: ""
      add :board, :string, null: false, default: ""
      add :size, :integer, null: false, default: 0

      add :uid, :string, null: false
      add :remote_author, :string
      add :peer_key, :binary
      add :rev, :integer, null: false, default: 1
      add :synced_rev, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:media_items, [:script_id])
    create unique_index(:media_items, [:script_id, :uid])
  end
end
