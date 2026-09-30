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
    field :crew_call, :string
    field :shooting_call, :string
    field :location, :string
    field :cast_calls, :map, default: %{}
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

  @time_re ~r/\A([01]\d|2[0-3]):[0-5]\d\z/

  def day_changeset(item, attrs) do
    item
    |> cast(attrs, [
      :shoot_date,
      :note,
      :position,
      :crew_call,
      :shooting_call,
      :location,
      :cast_calls
    ])
    |> put_change(:kind, "day")
    |> update_change(:note, &clean_note/1)
    |> update_change(:location, &clean_note/1)
    |> update_change(:cast_calls, &clean_calls/1)
    |> validate_format(:crew_call, @time_re, message: "use 24-hour HH:MM")
    |> validate_format(:shooting_call, @time_re, message: "use 24-hour HH:MM")
    |> validate_required([:position])
  end

  # Character name => "HH:MM"; blanks and malformed times are dropped.
  defp clean_calls(calls) when is_map(calls) do
    calls
    |> Enum.filter(fn {name, time} ->
      is_binary(name) and String.length(name) <= 120 and is_binary(time) and
        Regex.match?(@time_re, time)
    end)
    |> Enum.take(200)
    |> Map.new()
  end

  defp clean_calls(_calls), do: %{}

  def kinds, do: @kinds

  defp clean_note(nil), do: nil
  defp clean_note(note), do: note |> String.trim() |> String.slice(0, 200)
end
