defmodule Moorland.Repo.Migrations.AddShotImage do
  use Ecto.Migration

  # A storyboard frame per shot: the file lives in the data folder
  # (media/<script id>/), the shot keeps its file name.
  def change do
    alter table(:shots) do
      add :image, :string
    end
  end
end
