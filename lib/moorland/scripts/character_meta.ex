defmodule Moorland.Scripts.CharacterMeta do
  use Ecto.Schema
  import Ecto.Changeset

  @genders ~w(unspecified female male nonbinary)

  schema "character_meta" do
    field :name, :string
    field :gender, :string, default: "unspecified"

    belongs_to :script, Moorland.Scripts.Script

    timestamps(type: :utc_datetime)
  end

  def genders, do: @genders

  def changeset(meta, attrs) do
    meta
    |> cast(attrs, [:script_id, :name, :gender])
    |> validate_required([:script_id, :name, :gender])
    |> validate_inclusion(:gender, @genders)
    |> validate_length(:name, max: 80)
    |> unique_constraint([:script_id, :name])
  end
end
