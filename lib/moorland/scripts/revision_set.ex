defmodule Moorland.Scripts.RevisionSet do
  use Ecto.Schema

  # The order production revisions go in once the white draft is locked.
  # After the last colour the cycle repeats as "Double Blue", then "Triple".
  @colors ~w(Blue Pink Yellow Green Goldenrod Buff Salmon Cherry)
  @rounds ["", "Double ", "Triple ", "Fourth "]

  schema "revision_sets" do
    field :color, :string
    field :base_content, :string, default: ""

    belongs_to :script, Moorland.Scripts.Script
    belongs_to :author, Moorland.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "The name of the nth revision set (0-based): Blue, Pink, ... Double Blue."
  def color_name(n) when is_integer(n) and n >= 0 do
    round = div(n, length(@colors))
    prefix = Enum.at(@rounds, round) || "#{round + 1}x "
    prefix <> Enum.at(@colors, rem(n, length(@colors)))
  end

  @doc "The base colour of a set's name, lower case, for styling: `\"Double Pink\"` gives `\"pink\"`."
  def color_key(name) do
    name |> String.split(" ") |> List.last() |> String.downcase()
  end
end
