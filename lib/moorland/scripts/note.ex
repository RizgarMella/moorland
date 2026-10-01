defmodule Moorland.Scripts.Note do
  use Ecto.Schema
  import Ecto.Changeset

  @colors ~w(yellow blue green pink gray)
  @kinds ~w(note sketch)

  schema "notes" do
    field :body, :string
    field :color, :string, default: "yellow"
    field :pinned, :boolean, default: false
    field :kind, :string, default: "note"

    # Peer sync (see Comment).
    field :uid, :string, autogenerate: {Ecto.UUID, :generate, []}
    field :remote_author, :string
    field :peer_key, :binary
    field :rev, :integer, default: 1
    field :synced_rev, :integer, default: 0
    field :from_assistant, :boolean, default: false

    belongs_to :script, Moorland.Scripts.Script
    belongs_to :author, Moorland.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def colors, do: @colors
  def kinds, do: @kinds

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:body, :color, :pinned, :kind])
    |> validate_required([:body])
    |> validate_inclusion(:color, @colors)
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:body, max: 5000)
  end
end
