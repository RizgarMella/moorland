defmodule Moorland.Scripts.ShotListTest do
  use ExUnit.Case, async: true

  alias Moorland.Scripts.ShotList

  @script "INT. HALL - DAY #4#\n\nThe lamp turns.\n\nEXT. CLIFF - NIGHT #5#\n\nWaves."

  defp shot(id, position, anchor, line),
    do: %{id: id, position: position, anchor_text: anchor, line_no: line, description: "#{id}"}

  test "numbers shots per scene with the scene's label, in position order" do
    list =
      ShotList.build(@script, [
        shot(1, 3, "lamp", 2),
        shot(2, 1, "lamp", 2),
        shot(3, 2, "Waves", 6)
      ])

    assert [%{label: "4", shots: [%{id: 2, number: "4A"}, %{id: 1, number: "4B"}]}, cliff] =
             list.scenes

    assert [%{id: 3, number: "5A"}] = cliff.shots
    assert list.total == 3
  end

  test "letters skip I and O and run on to double letters" do
    letters = Enum.map(0..25, &ShotList.shot_number("1", &1))
    refute "1I" in letters or "1O" in letters
    assert Enum.at(letters, 7) == "1H" and Enum.at(letters, 8) == "1J"
    assert ShotList.shot_number("1", 24) == "1AA"
    assert ShotList.shot_number(nil, 0) == "—A"
  end

  test "shots whose words are gone are unplaced" do
    list = ShotList.build(@script, [shot(1, 0, "helicopter", 2)])
    assert [%{id: 1}] = list.unplaced
    assert list.total == 0
  end
end
