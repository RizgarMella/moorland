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
  sections. Stage plays, multi-camera sitcoms and comic scripts are Fountain
  as well, laid out their own way: a play's acts and scenes are `#` and
  `##` sections; a comic's pages and panels are.
  """
  def kinds, do: ~w(screenplay prose podcast lesson stageplay multicam comic)

  @doc "What each kind is called where a person reads it."
  def kind_label("screenplay"), do: "Screenplay"
  def kind_label("prose"), do: "Prose"
  def kind_label("podcast"), do: "Podcast"
  def kind_label("lesson"), do: "Lesson"
  def kind_label("stageplay"), do: "Stage play"
  def kind_label("multicam"), do: "Multi-cam"
  def kind_label("comic"), do: "Comic"
  def kind_label(other), do: to_string(other)

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

  def template("stageplay") do
    """
    Title: The Keeper
    Credit: A play in two acts by
    Author: Your name

    # ACT ONE

    ## Scene 1

    The lamp room of a lighthouse. Night. The great lens turns slowly overhead. ANNA, thirties, sits on the iron stairs with a ledger.

    ANNA
    Two hundred and twelve.

    TOM
    (offstage)
    You'll wear them out, counting.

    TOM enters with two mugs and hands her one.

    ANNA
    Somebody has to.

    ## Scene 2

    The same. Morning. The lamp is dark.

    # ACT TWO

    ## Scene 1

    The harbour wall. Gulls.
    """
  end

  def template("multicam") do
    """
    Title: Pilot
    Credit: Written by
    Author: Your name

    # COLD OPEN

    INT. LIGHTHOUSE KITCHEN - NIGHT (NIGHT 1)

    ANNA is at the stove. TOM enters, soaked to the skin.

    TOM
    It's raining sideways.

    ANNA
    It does that. We live on a rock.

    # ACT ONE

    INT. HARBOUR CAFE - DAY (DAY 1)

    MARGO wipes the counter as ANNA comes in.

    MARGO
    The usual?

    ANNA
    Surprise me.

    MARGO
    (pouring)
    Surprise.
    """
  end

  def template("comic") do
    """
    Title: The Keeper #1
    Credit: Written by
    Author: Your name

    # PAGE ONE

    ## Panel 1

    Wide. A lighthouse on a black rock, a storm breaking over it. The beam cuts the rain.

    CAPTION
    Gull Point. The last manned light on the coast.

    ## Panel 2

    Inside the lamp room. ANNA climbs the iron stairs, ledger under her arm.

    ANNA
    Two hundred and twelve.

    ## Panel 3

    Close on the ledger: a column of numbers, all the same.

    SFX
    KRAKOOM

    # PAGE TWO

    ## Panel 1

    The lamp flickers.
    """
  end

  # Not a kind: a prose document that starts as a treatment.
  def template("treatment") do
    """
    ---
    title: Treatment title
    author: Your name
    ---

    # Logline

    One sentence: who wants what, and what stands in the way.

    # Characters

    **Anna**, thirties, keeper of the last manned light on the coast.

    **Tom**, her brother, who wants to sell it.

    # Story

    Tell the film in the present tense, scene by scene, the way it plays.

    Night at Gull Point. Anna climbs the two hundred and twelve stairs, as she has every night for ten years...
    """
  end

  def template(_kind), do: ""

  def stageplay?(%__MODULE__{kind: "stageplay"}), do: true
  def stageplay?(_script), do: false

  def comic?(%__MODULE__{kind: "comic"}), do: true
  def comic?(_script), do: false

  @doc "Kinds written with scene headings, which breakdowns, sides and schedules read."
  def sluglines?(%__MODULE__{kind: kind}), do: kind in ["screenplay", "multicam"]
  def sluglines?(_script), do: false

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
