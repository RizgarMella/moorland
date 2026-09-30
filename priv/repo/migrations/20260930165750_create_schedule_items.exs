defmodule Moorland.Repo.Migrations.CreateScheduleItems do
  use Ecto.Migration

  # The stripboard: one ordered list per script of scene strips and
  # end-of-day breaks, the way a physical board is a column of strips with
  # day-break strips between shoot days.
  #
  # A scene strip remembers its heading and the line it was on; the scene is
  # found fresh from the text each time (see Scripts.Schedule), as tags are.
  # A day break carries an optional shoot date and a note.
  def change do
    create table(:schedule_items) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :position, :integer, null: false
      add :heading, :string
      add :line_no, :integer, null: false, default: 0
      add :shoot_date, :date
      add :note, :string
      add :uid, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:schedule_items, [:script_id, :position])
    create unique_index(:schedule_items, [:script_id, :uid])
  end
end
