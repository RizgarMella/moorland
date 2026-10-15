defmodule Moorland.Scripts.PeerShare do
  use Ecto.Schema
  import Ecto.Changeset

  # A commenter peer (an AI assistant, say) adds comments, notes and tags
  # but never changes the text.
  @roles ~w(editor commenter viewer)

  schema "script_peer_shares" do
    field :role, :string, default: "editor"

    belongs_to :script, Moorland.Scripts.Script
    belongs_to :peer, Moorland.Peers.Peer
    # Set when the peer receives the script through this studio instead of
    # from us directly; the studio holds a copy and stands in while we're away.
    belongs_to :studio_peer, Moorland.Peers.Peer

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  def changeset(share, attrs) do
    share
    |> cast(attrs, [:script_id, :peer_id, :role, :studio_peer_id])
    |> validate_required([:script_id, :peer_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:script_id, :peer_id])
  end
end
