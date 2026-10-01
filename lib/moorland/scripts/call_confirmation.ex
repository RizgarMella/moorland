defmodule Moorland.Scripts.CallConfirmation do
  use Ecto.Schema

  schema "call_confirmations" do
    field :day_uid, :string
    field :name, :string
    field :uid, :string, autogenerate: {Ecto.UUID, :generate, []}
    field :peer_key, :binary
    field :synced_at, :utc_datetime

    belongs_to :script, Moorland.Scripts.Script
    belongs_to :user, Moorland.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
