defmodule Moorland.Scripts.PipelineTest do
  use ExUnit.Case, async: true

  alias Moorland.Scripts.{Pipeline, Stats}

  @story """
  # The Lighthouse

  ## Night

  Anna climbed the stairs. The lamp was *out*.

  It had never been out.

  ***

  Morning came grey.

  # The Town

  Nobody believed her. */ Not even Tom.

  /* a cut line */
  """

  test "stages run idea, short story, story, script" do
    assert Pipeline.next("idea") == "short_story"
    assert Pipeline.next("story") == "script"
    assert Pipeline.next("script") == nil
    assert Pipeline.kind_for("story") == "prose"
    assert Pipeline.kind_for("script") == "screenplay"
    assert Pipeline.label("short_story") == "Short story"
  end

  test "chapters become sections, scenes and breaks become stubs with their prose kept" do
    script = Pipeline.adapt(@story)

    assert script =~ "# The Lighthouse"

    assert script =~
             ".NIGHT\n\n= Anna climbed the stairs.\n\n/*\nAnna climbed the stairs. The lamp was *out*."

    assert script =~ ".NEW SCENE\n\n= Morning came grey."
    assert script =~ "# The Town\n\n.THE TOWN\n\n= Nobody believed her."
    # A stray "*/" in the prose cannot close the boneyard early; the cut line is gone.
    assert script =~ "* / Not even Tom."
    refute script =~ "a cut line"
  end

  test "the result is a script with the stubs as scenes and no words of prose" do
    stats = Stats.compute(Pipeline.adapt(@story))
    assert stats.scene_count == 3

    assert Enum.map(Stats.scenes(Pipeline.adapt(@story)), & &1.heading) == [
             "NIGHT",
             "NEW SCENE",
             "THE TOWN"
           ]
  end

  test "a story without headings becomes one stub" do
    assert [%{heading: "NEW SCENE"}] =
             Stats.scenes(Pipeline.adapt("Just one paragraph. Then more."))

    assert Stats.scenes(Pipeline.adapt("")) == []
  end
end
