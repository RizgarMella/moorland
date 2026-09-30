defmodule Moorland.Repo.Migrations.AddScheduleSync do
  use Ecto.Migration

  # The stripboard travels between installations as a whole board. On a
  # mirror, every local change to the board bumps schedule_rev; a push that
  # the origin accepts records it in schedule_synced_rev. The two differing
  # means the mirror's board is still to push, and a pull must not replace it.
  def change do
    alter table(:scripts) do
      add :schedule_rev, :integer, null: false, default: 0
      add :schedule_synced_rev, :integer, null: false, default: 0
    end
  end
end
