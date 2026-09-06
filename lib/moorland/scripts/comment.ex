defmodule Moorland.Scripts.Comment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "comments" do
    field :line_no, :integer
    field :anchor_text, :string
    field :body, :string
    field :resolved_at, :utc_datetime

    # Peer sync: global id, display handle for authors on other installs,
    # which peer it came from, and (on mirrors) which revision was pushed.
    field :uid, :string, autogenerate: {Ecto.UUID, :generate, []}
    field :remote_author, :string
    field :peer_key, :binary
    field :rev, :integer, default: 1
    field :synced_rev, :integer, default: 0

    belongs_to :script, Moorland.Scripts.Script
    belongs_to :author, Moorland.Accounts.User
    belongs_to :parent, __MODULE__
    has_many :replies, __MODULE__, foreign_key: :parent_id

    timestamps(type: :utc_datetime)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:line_no, :anchor_text, :body, :parent_id])
    |> validate_required([:body])
    |> validate_length(:body, max: 5000)
    |> update_change(:anchor_text, &String.slice(&1 || "", 0, 200))
  end
end
