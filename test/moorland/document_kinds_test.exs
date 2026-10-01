defmodule Moorland.DocumentKindsTest do
  use ExUnit.Case, async: true

  alias Moorland.Scripts.{Script, Stats}

  test "every new kind starts from a template its statistics read" do
    stage = Stats.compute_for(%{kind: "stageplay"}, Script.template("stageplay"))
    assert stage.stage
    assert stage.acts == 2
    assert stage.scene_count == 3
    assert Enum.map(stage.characters, & &1.name) |> Enum.sort() == ["ANNA", "TOM"]

    multicam = Stats.compute_for(%{kind: "multicam"}, Script.template("multicam"))
    screenplay = Stats.compute(Script.template("multicam"))
    assert multicam.multicam
    assert multicam.scene_count == 2
    assert multicam.acts == 2
    assert multicam.pages == screenplay.pages * 2
    assert multicam.minutes == screenplay.minutes

    comic = Stats.compute_for(%{kind: "comic"}, Script.template("comic"))
    assert comic.comic
    assert comic.pages == 2
    assert comic.panels == 4
    assert comic.balloons == 3

    assert [%{title: "PAGE ONE", panels: 3, balloons: 3}, %{title: "PAGE TWO", panels: 1}] =
             comic.page_list
  end

  test "comic pages flag crowding and long balloons" do
    panels = Enum.map_join(1..7, "\n\n", &"## Panel #{&1}\n\nA beat.")
    long = Enum.map_join(1..30, " ", fn _ -> "word" end)

    text =
      "# PAGE ONE\n\n#{panels}\n\nANNA\n#{long}\n\nCAPTION\nShort.\n\n# PAGE TWO\n\n## Panel 1"

    [one, two] = Stats.compute_comic(text).page_list
    assert one.panels == 7 and one.crowded
    assert one.balloons == 2 and one.long_balloons == 1
    assert one.words == 31
    refute two.crowded
  end

  test "sections in the boneyard don't count" do
    text = "# ACT ONE\n\n## Scene 1\n\n/*\n## Scene 2\n*/\n\nANNA\nHello."
    assert Stats.compute_stageplay(text).scene_count == 1
  end

  test "kinds have labels; only slugline kinds feed breakdowns" do
    assert Script.kind_label("comic") == "Comic"
    assert Script.sluglines?(%Script{kind: "multicam"})
    refute Script.sluglines?(%Script{kind: "stageplay"})
    assert "comic" in Script.kinds()
    assert Script.template("treatment") =~ "# Logline"
  end
end
