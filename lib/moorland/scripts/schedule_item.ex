defmodule Moorland.Scripts.ScheduleItem do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(scene day)

  schema "schedule_items" do
    field :kind, :string
    field :position, :integer
    field :heading, :string
    field :line_no, :integer, default: 0
    field :shoot_date, :date
    field :note, :string
    field :uid, :string, autogenerate: {Ecto.UUID, :generate, []}

    belongs_to :script, Moorland.Scripts.Script

    timestamps(type: :utc_datetime)
  end

  def scene_changeset(item, attrs) do
    item
    |> cast(attrs, [:heading, :line_no, :position])
    |> put_change(:kind, "scene")
    |> validate_required([:heading, :line_no, :position])
    |> validate_length(:heading, max: 200)
    |> validate_number(:line_no, greater_than_or_equal_to: 0)
  end

  def day_changeset(item, attrs) do
    item
    |> cast(attrs, [:shoot_date, :note, :position])
    |> put_change(:kind, "day")
    |> update_change(:note, &clean_note/1)
    |> validate_required([:position])
  end

  def kinds, do: @kinds

  defp clean_note(nil), do: nil
  defp clean_note(note), do: note |> String.trim() |> String.slice(0, 200)
end
