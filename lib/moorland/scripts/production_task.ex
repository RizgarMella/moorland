defmodule Moorland.Scripts.ProductionTask do
  use Ecto.Schema
  import Ecto.Changeset

  @phases [{"prep", "Prep"}, {"shoot", "Shoot"}, {"post", "Post"}]
  @statuses [{"todo", "To do"}, {"doing", "Doing"}, {"done", "Done"}]

  schema "tasks" do
    field :title, :string
    field :phase, :string, default: "prep"
    field :status, :string, default: "todo"
    field :assignee, :string
    field :starts_on, :date
    field :due_on, :date

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

  def phases, do: @phases
  def statuses, do: @statuses
  def phase_keys, do: Enum.map(@phases, &elem(&1, 0))
  def status_keys, do: Enum.map(@statuses, &elem(&1, 0))

  def label(key) do
    case List.keyfind(@phases ++ @statuses, key, 0) do
      {_, label} -> label
      nil -> key
    end
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :phase, :status, :assignee, :starts_on, :due_on])
    |> update_change(:title, &String.trim/1)
    |> update_change(:assignee, &clean/1)
    |> validate_required([:title, :phase, :status])
    |> validate_length(:title, max: 200)
    |> validate_length(:assignee, max: 80)
    |> validate_inclusion(:phase, phase_keys())
    |> validate_inclusion(:status, status_keys())
    |> validate_dates()
  end

  defp clean(nil), do: nil

  defp clean(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # A span needs an end, and cannot end before it starts.
  defp validate_dates(changeset) do
    starts = get_field(changeset, :starts_on)
    due = get_field(changeset, :due_on)

    cond do
      starts && is_nil(due) ->
        add_error(changeset, :due_on, "is needed when there is a start date")

      starts && Date.compare(due, starts) == :lt ->
        add_error(changeset, :due_on, "is before the start")

      true ->
        changeset
    end
  end

  @doc "Not done and due before `today`."
  def overdue?(%{status: status, due_on: %Date{} = due}, today),
    do: status != "done" and Date.compare(due, today) == :lt

  def overdue?(_task, _today), do: false

  @doc "Does the task show on `day`: its span covers it, or it is due that day."
  def on_day?(%{starts_on: %Date{} = s, due_on: %Date{} = d}, day),
    do: Date.compare(day, s) != :lt and Date.compare(day, d) != :gt

  def on_day?(%{due_on: %Date{} = d}, day), do: Date.compare(day, d) == :eq
  def on_day?(_task, _day), do: false
end
