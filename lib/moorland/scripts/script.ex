defmodule Moorland.Scripts.Script do
  use Ecto.Schema
  import Ecto.Changeset

  schema "scripts" do
    field :title, :string
    field :content, :string, default: ""
    field :content_version, :integer, default: 0
    field :kind, :string, default: "screenplay"
    # Story-to-script pipeline (see Scripts.Pipeline); nil outside one.
    field :stage, :string
    field :parent_script_id, :integer
    # Locked pages (see Scripts.lock_pages/3); nil when pages run free.
    field :page_lock, :map
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

  @doc """
  Screenplays are written in Fountain; prose (stories, books) in Markdown;
  podcast episodes in Fountain too, with hosts as cues and segments as
  sections.
  """
  def kinds, do: ~w(screenplay prose podcast lesson)

  def lesson?(%__MODULE__{kind: "lesson"}), do: true
  def lesson?(_script), do: false

  def podcast?(%__MODULE__{kind: "podcast"}), do: true
  def podcast?(_script), do: false

  @doc "Where a new document of this kind starts."
  def template("podcast") do
    """
    Title: Episode title
    Credit: Hosted by
    Author: Your name

    # Cold open
    = 0:30

    HOST
    One line that makes them stay.

    # Intro

    HOST
    Welcome to the show. Today...

    # Segment one

    HOST
    So tell me how it started.

    GUEST
    It started with a lamp that went out.

    # Ad break
    = 1:00

    # Outro

    HOST
    Thanks for listening.
    """
  end

  def template("lesson") do
    """
    Title: Lesson title
    Objectives:
        Name the three parts of a lighthouse
        Explain why the lamp turns
    Author: Your name

    # Hook

    A storm at sea. A single beam sweeps across the waves.

    NARRATOR
    For two hundred years, one light stood between sailors and the rocks.

    # The parts

    ON SCREEN: Diagram of a lighthouse, the lantern room highlighted.

    NARRATOR
    Every lighthouse has three parts: the tower, the lantern room, and the lamp.

    # Recap

    ON SCREEN: Key points, one at a time.

    NARRATOR
    So: a tall tower, a glass room, and a turning light.
    """
  end

  def template(_kind), do: ""

  def prose?(%__MODULE__{kind: "prose"}), do: true
  def prose?(_script), do: false

  # A stage is written as one kind: ideas and stories in prose, scripts
  # as screenplays.
  defp validate_stage_kind(changeset) do
    stage = get_field(changeset, :stage)
    kind = get_field(changeset, :kind)

    if stage && Moorland.Scripts.Pipeline.kind_for(stage) not in [nil, kind],
      do: add_error(changeset, :stage, "doesn't fit a #{kind}"),
      else: changeset
  end

  def changeset(script, attrs) do
    script
    |> cast(attrs, [:title, :content, :goal_words, :goal_pages, :kind, :stage])
    |> validate_required([:title])
    |> validate_inclusion(:kind, kinds())
    |> validate_inclusion(:stage, Moorland.Scripts.Pipeline.stage_keys())
    |> validate_stage_kind()
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
