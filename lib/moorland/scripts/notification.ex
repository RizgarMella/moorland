defmodule Moorland.Scripts.Notification do
  use Ecto.Schema

  schema "notifications" do
    field :kind, :string, default: "comment"
    field :body, :string
    field :read_at, :utc_datetime

    belongs_to :user, Moorland.Accounts.User
    belongs_to :script, Moorland.Scripts.Script
    belongs_to :comment, Moorland.Scripts.Comment

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
