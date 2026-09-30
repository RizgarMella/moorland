defmodule Moorland.Scripts.BreakdownTag do
  use Ecto.Schema
  import Ecto.Changeset

  # The departments of a standard breakdown sheet, in sheet order.
  @categories [
    {"cast", "Cast"},
    {"extras", "Background"},
    {"stunts", "Stunts"},
    {"props", "Props"},
    {"set_dressing", "Set dressing"},
    {"wardrobe", "Wardrobe"},
    {"makeup", "Makeup & hair"},
    {"vehicles", "Vehicles"},
    {"animals", "Animals"},
    {"sfx", "Special effects"},
    {"vfx", "Visual effects"},
    {"sound", "Sound & music"},
    {"equipment", "Special equipment"}
  ]

  @category_keys Enum.map(@categories, &elem(&1, 0))

  schema "breakdown_tags" do
    field :category, :string
    field :name, :string
    field :anchor_text, :string
    field :line_no, :integer, default: 0

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

  @doc "`[{key, label}]` for every category, in breakdown-sheet order."
  def categories, do: @categories

  def category_keys, do: @category_keys

  def category_label(key) do
    case List.keyfind(@categories, key, 0) do
      {_, label} -> label
      nil -> key
    end
  end

  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:category, :name, :anchor_text, :line_no])
    |> update_change(:name, &clean_name/1)
    |> update_change(:anchor_text, &String.slice(String.trim(&1 || ""), 0, 200))
    |> validate_required([:category, :name, :line_no])
    |> validate_inclusion(:category, @category_keys)
    |> validate_length(:name, max: 120)
    |> validate_number(:line_no, greater_than_or_equal_to: 0)
  end

  defp clean_name(nil), do: nil
  defp clean_name(name), do: name |> String.replace(~r/\s+/, " ") |> String.trim()
end
