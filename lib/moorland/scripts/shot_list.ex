defmodule Moorland.Scripts.ShotList do
  @moduledoc """
  The shot list as pure functions: shots placed in their scenes by the words
  they were anchored to (see `Breakdown.place/2`), ordered by position and
  numbered as productions number them, the scene's number plus a letter:
  12A, 12B... I and O are skipped, being too easily read as 1 and 0.
  """

  alias Moorland.Scripts.Breakdown

  @letters ~w(A B C D E F G H J K L M N P Q R S T U V W X Y Z)

  @doc """
  `%{scenes, unplaced, total}`: every scene with its `:shots`, each shot
  map carrying a `:number` such as `"12A"`, plus shots whose words are gone.
  """
  def build(text, shots) do
    {scenes, placed, unplaced} = Breakdown.place(text, shots)

    scenes =
      Enum.map(scenes, fn scene ->
        numbered =
          placed
          |> Map.get(scene.number, [])
          |> Enum.sort_by(&{&1.position, &1.id})
          |> Enum.with_index()
          |> Enum.map(fn {shot, i} -> Map.put(shot, :number, shot_number(scene.label, i)) end)

        Map.put(scene, :shots, numbered)
      end)

    %{
      scenes: scenes,
      unplaced: unplaced,
      total: scenes |> Enum.map(&length(&1.shots)) |> Enum.sum()
    }
  end

  @doc "The nth (0-based) shot of a scene: 12A, 12B... 12Z, 12AA."
  def shot_number(scene_label, n) do
    (scene_label || "—") <> letters(n)
  end

  defp letters(n) when n < length(@letters), do: Enum.at(@letters, n)

  defp letters(n) do
    count = length(@letters)
    letters(div(n, count) - 1) <> Enum.at(@letters, rem(n, count))
  end
end
