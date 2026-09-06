defmodule Moorland.Scripts.StatsTest do
  use ExUnit.Case, async: true

  alias Moorland.Scripts.Stats

  @script """
  Title: Demo
  Author: Riz

  INT. LAB - DAY

  The machine hums quietly in the corner.

  NORA
  It works. It finally works.

  EDDIE
  (unconvinced)
  Define "works".

  EXT. PARKING LOT - NIGHT

  Rain. NORA runs to her car.

  NORA (V.O.)
  Every experiment needs a witness.

  INT. LAB

  EDDIE
  She left the machine on.
  """

  test "counts scenes, splitting INT/EXT and times" do
    stats = Stats.compute(@script)
    assert stats.scene_count == 3
    assert stats.int_ext == %{int: 2, ext: 1, other: 0}
    assert {"DAY", 1} in stats.times
    assert {"NIGHT", 1} in stats.times
    assert {"UNSPECIFIED", 1} in stats.times
  end

  test "speaking parts merge extensions and count lines and words" do
    stats = Stats.compute(@script)
    nora = Enum.find(stats.characters, &(&1.name == "NORA"))
    eddie = Enum.find(stats.characters, &(&1.name == "EDDIE"))
    # NORA and NORA (V.O.) are the same part
    assert nora.lines == 2
    assert eddie.lines == 2
    assert nora.words > 0
  end

  test "locations aggregate by frequency" do
    stats = Stats.compute(@script)
    assert {"LAB", 2} in stats.locations
    assert {"PARKING LOT", 1} in stats.locations
  end

  test "pages and runtime estimates are positive and equal" do
    stats = Stats.compute(@script)
    assert stats.pages >= 1
    assert stats.minutes == stats.pages
    assert stats.words > 20
  end

  test "empty script yields zeros" do
    stats = Stats.compute("")
    assert stats.pages == 0
    assert stats.scene_count == 0
    assert stats.characters == []
  end

  test "title page and boneyard are excluded" do
    stats = Stats.compute("Title: X\nAuthor: Y\n\n/* NORA\nhidden */\n\nINT. A - DAY\n\nHi.")
    assert stats.scene_count == 1
    assert stats.characters == []
  end
end
