defmodule Moorland.Scripts.Script do
  use Ecto.Schema
  import Ecto.Changeset

  schema "scripts" do
    field :title, :string
    field :content, :string, default: ""
    field :content_version, :integer, default: 0
    field :kind, :string, default: "screenplay"
    field :goal_words, :integer
    field :goal_pages, :integer

    # Set on mirrors of a peer's script; nil for scripts this install owns.
    field :origin_public_key, :binary
    field :origin_script_id, :integer
    field :origin_version, :integer, default: 0
    field :origin_content, :string
    field :origin_role, :string
    field :origin_activity_stamp, :string
    field :schedule_rev, :integer, default: 0
    field :schedule_synced_rev, :integer, default: 0

    belongs_to :owner, Moorland.Accounts.User
    has_many :collaborators, Moorland.Scripts.Collaborator
    has_many :versions, Moorland.Scripts.Version
    has_many :comments, Moorland.Scripts.Comment
    has_many :notes, Moorland.Scripts.Note

    timestamps(type: :utc_datetime)
  end

  @doc "Screenplays are written in Fountain; prose (stories, books) in Markdown."
  def kinds, do: ~w(screenplay prose)

  def prose?(%__MODULE__{kind: "prose"}), do: true
  def prose?(_script), do: false

  def changeset(script, attrs) do
    script
    |> cast(attrs, [:title, :content, :goal_words, :goal_pages, :kind])
    |> validate_required([:title])
    |> validate_inclusion(:kind, kinds())
    |> validate_length(:title, max: 200)
    |> validate_number(:goal_words, greater_than_or_equal_to: 0, less_than: 10_000_000)
    |> validate_number(:goal_pages, greater_than_or_equal_to: 0, less_than: 100_000)
  end

  def content_changeset(script, attrs) do
    script
    |> cast(attrs, [:content])
    |> validate_required([])
  end
end
