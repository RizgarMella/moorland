defmodule Moorland.Repo.Migrations.AddStudioMode do
  use Ecto.Migration

  def change do
    # This installation relays its members' shared scripts.
    alter table(:peer_identity) do
      add :studio, :boolean, default: false, null: false
    end

    # A peer that told us it is a studio.
    alter table(:peers) do
      add :studio, :boolean, default: false, null: false
    end

    # A share delivered through a studio rather than directly.
    alter table(:script_peer_shares) do
      add :studio_peer_id, references(:peers, on_delete: :nilify_all)
    end

    create index(:script_peer_shares, [:studio_peer_id])
  end
end
