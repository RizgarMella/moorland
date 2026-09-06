defmodule Moorland.Peers.Identity do
  use Ecto.Schema
  import Ecto.Changeset

  schema "peer_identity" do
    field :name, :string, default: "My Moorland"
    field :public_key, :binary
    field :private_key, :binary, redact: true
    field :host, :string, default: "127.0.0.1"
    field :port, :integer, default: 4000

    timestamps(type: :utc_datetime)
  end

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:name, :host, :port])
    |> validate_required([:name, :host, :port])
    |> validate_length(:name, max: 80)
    |> validate_length(:host, max: 255)
    |> validate_inclusion(:port, 1..65_535)
  end
end
