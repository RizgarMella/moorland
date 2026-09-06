defmodule Moorland.Scripts.PeerShare do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(editor viewer)

  schema "script_peer_shares" do
    field :role, :string, default: "editor"

    belongs_to :script, Moorland.Scripts.Script
    belongs_to :peer, Moorland.Peers.Peer

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  def changeset(share, attrs) do
    share
    |> cast(attrs, [:script_id, :peer_id, :role])
    |> validate_required([:script_id, :peer_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:script_id, :peer_id])
  end
end
