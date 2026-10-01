defmodule Moorland.Scripts.Shot do
  use Ecto.Schema
  import Ecto.Changeset

  @sizes ~w(EWS WS FS MS MCU CU ECU INSERT OTS POV TWO)
  @angles ~w(eye high low overhead dutch)
  @movements ~w(static pan tilt dolly track handheld steadicam crane zoom)

  schema "shots" do
    field :anchor_text, :string
    field :line_no, :integer, default: 0
    field :position, :integer, default: 0
    field :size, :string
    field :angle, :string
    field :movement, :string
    field :lens, :string
    field :description, :string, default: ""
    # Storyboard frame: a file name under Storage.media_dir/<script id>.
    field :image, :string

    # Peer sync (see Comment).
    field :uid, :string, autogenerate: {Ecto.UUID, :generate, []}
    field :remote_author, :string
    field :peer_key, :binary
    field :rev, :integer, default: 1
    field :synced_rev, :integer, default: 0

    belongs_to :script, Moorland.Scripts.Script
    belongs_to :author, Moorland.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def sizes, do: @sizes
  def angles, do: @angles
  def movements, do: @movements

  def size_label("EWS"), do: "Extreme wide"
  def size_label("WS"), do: "Wide"
  def size_label("FS"), do: "Full"
  def size_label("MS"), do: "Medium"
  def size_label("MCU"), do: "Medium close-up"
  def size_label("CU"), do: "Close-up"
  def size_label("ECU"), do: "Extreme close-up"
  def size_label("INSERT"), do: "Insert"
  def size_label("OTS"), do: "Over the shoulder"
  def size_label("POV"), do: "Point of view"
  def size_label("TWO"), do: "Two-shot"
  def size_label(other), do: other

  def changeset(shot, attrs) do
    shot
    |> cast(attrs, [
      :anchor_text,
      :line_no,
      :position,
      :size,
      :angle,
      :movement,
      :lens,
      :description
    ])
    |> update_change(:anchor_text, &String.slice(String.trim(&1 || ""), 0, 200))
    |> update_change(:lens, &String.slice(String.trim(&1 || ""), 0, 40))
    |> update_change(:description, &String.trim(&1 || ""))
    |> validate_required([:line_no])
    |> validate_inclusion(:size, @sizes)
    |> validate_inclusion(:angle, @angles)
    |> validate_inclusion(:movement, @movements)
    |> validate_length(:description, max: 2000)
    |> validate_number(:line_no, greater_than_or_equal_to: 0)
  end
end
