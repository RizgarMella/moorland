defmodule Moorland.Scripts.Suggestion do
  use Ecto.Schema

  schema "suggestions" do
    field :uid, :string
    field :message, :string, default: ""
    field :content, :string
    field :base_version, :integer, default: 0
    field :status, :string, default: "open"
    field :remote_author, :string
    field :peer_key, :binary
    field :from_assistant, :boolean, default: false

    belongs_to :script, Moorland.Scripts.Script
    belongs_to :decided_by, Moorland.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
