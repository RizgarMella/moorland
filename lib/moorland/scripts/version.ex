defmodule Moorland.Scripts.Version do
  use Ecto.Schema
  import Ecto.Changeset

  schema "script_versions" do
    field :message, :string
    field :kind, :string, default: "manual"
    field :content, :string

    # Peer sync (see Comment); origin_id is the id on the origin install.
    field :uid, :string, autogenerate: {Ecto.UUID, :generate, []}
    field :remote_author, :string
    field :peer_key, :binary
    field :origin_id, :integer
    field :synced_at, :utc_datetime

    belongs_to :script, Moorland.Scripts.Script
    belongs_to :author, Moorland.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [:message, :kind, :content, :script_id, :author_id])
    |> validate_required([:kind, :content, :script_id])
    |> validate_inclusion(:kind, ~w(manual auto restore))
    |> validate_length(:message, max: 200)
  end
end
