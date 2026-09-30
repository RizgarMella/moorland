defmodule Moorland.Repo.Migrations.AddCallSheetFields do
  use Ecto.Migration

  # Call sheet details live on the day's end-of-day break: crew and shooting
  # call times, where the unit is, and each cast member's call, keyed by
  # character name.
  def change do
    alter table(:schedule_items) do
      add :crew_call, :string
      add :shooting_call, :string
      add :location, :string
      add :cast_calls, :map, null: false, default: %{}
    end
  end
end
