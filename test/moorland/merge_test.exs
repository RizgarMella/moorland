defmodule Moorland.Scripts.MergeTest do
  use ExUnit.Case, async: true

  alias Moorland.Scripts.Merge

  @base "INT. LAB - DAY\n\nThe machine hums.\n\nNORA\nIt works.\n\nEXT. LOT - NIGHT\n\nRain falls."

  test "identical sides pass through" do
    assert Merge.three_way(@base, @base, @base) == @base
  end

  test "only theirs changed" do
    theirs = String.replace(@base, "Rain falls.", "Snow falls.")
    assert Merge.three_way(@base, @base, theirs) == theirs
  end

  test "only ours changed" do
    ours = String.replace(@base, "Rain falls.", "Snow falls.")
    assert Merge.three_way(@base, ours, @base) == ours
  end

  test "edits in different regions are both kept" do
    ours = String.replace(@base, "The machine hums.", "The machine roars.")
    theirs = String.replace(@base, "Rain falls.", "Snow falls.")
    merged = Merge.three_way(@base, ours, theirs)
    assert merged =~ "The machine roars."
    assert merged =~ "Snow falls."
    refute merged =~ "The machine hums."
    refute merged =~ "Rain falls."
  end

  test "both sides appending keeps both additions" do
    ours = @base <> "\n\nNORA\nMine first."
    theirs = @base <> "\n\nEDDIE\nMine too."
    merged = Merge.three_way(@base, ours, theirs)
    assert merged =~ "Mine first."
    assert merged =~ "Mine too."
  end

  test "same region rewritten differently: incoming save wins there only" do
    ours = String.replace(@base, "It works.", "It hums along.")
    theirs = String.replace(@base, "It works.", "It sings.")
    # ours also made a separate edit elsewhere that must survive
    ours = String.replace(ours, "Rain falls.", "Hail falls.")
    merged = Merge.three_way(@base, ours, theirs)
    assert merged =~ "It sings."
    refute merged =~ "It hums along."
    assert merged =~ "Hail falls."
  end

  test "delete versus edit overlap resolves to the incoming save" do
    ours = String.replace(@base, "\n\nEXT. LOT - NIGHT\n\nRain falls.", "")
    theirs = String.replace(@base, "Rain falls.", "Rain hammers.")
    merged = Merge.three_way(@base, ours, theirs)
    assert merged =~ "Rain hammers."
  end

  test "insertion next to an edit keeps both" do
    ours = String.replace(@base, "NORA\nIt works.", "NORA\n(smiling)\nIt works.")
    theirs = String.replace(@base, "The machine hums.", "The machine crackles.")
    merged = Merge.three_way(@base, ours, theirs)
    assert merged =~ "(smiling)"
    assert merged =~ "The machine crackles."
  end
end
