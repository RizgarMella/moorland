defmodule Moorland.Peers.Peer do
  use Ecto.Schema
  import Ecto.Changeset

  schema "peers" do
    field :name, :string
    field :public_key, :binary
    field :host, :string
    field :port, :integer
    field :last_seen_at, :utc_datetime
    field :last_error, :string

    belongs_to :added_by, Moorland.Accounts.User, foreign_key: :added_by_user_id

    timestamps(type: :utc_datetime)
  end

  def changeset(peer, attrs) do
    peer
    |> cast(attrs, [:name, :public_key, :host, :port, :added_by_user_id])
    |> validate_required([:name, :public_key, :host, :port, :added_by_user_id])
    |> validate_length(:name, max: 80)
    |> validate_inclusion(:port, 1..65_535)
    |> unique_constraint(:public_key)
  end
end
