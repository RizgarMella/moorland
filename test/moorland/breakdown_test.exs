defmodule Moorland.Scripts.BreakdownTest do
  use ExUnit.Case, async: true

  alias Moorland.Scripts.{Breakdown, Stats}

  @script """
  Title: The Heist
  Author: Someone

  INT. BANK VAULT - NIGHT

  RAY cracks the safe with a *crowbar*. Gunther watches.

  RAY
  Hand me the gun.

  MAYA (V.O.)
  Hurry.

  EXT. ALLEY - DAY

  A getaway van idles. The gun lies in a puddle.

  MAYA
  Go!
  """

  defp tag(attrs) do
    Map.merge(%{id: System.unique_integer(), anchor_text: nil, line_no: 0, author: nil}, attrs)
  end

  describe "Stats.scenes/1" do
    test "numbers scenes with their source lines, despite the title page" do
      [vault, alley] = Stats.scenes(@script)

      assert %{number: 1, line: 3, heading: "INT. BANK VAULT - NIGHT", end_line: 12} = vault
      assert %{number: 2, line: 13, heading: "EXT. ALLEY - DAY"} = alley
      assert vault.int_ext == :int and alley.int_ext == :ext
      assert vault.time == "NIGHT" and alley.location == "ALLEY"
    end

    test "lists each speaking part once, without extensions" do
      [vault, alley] = Stats.scenes(@script)
      assert vault.cast == ["RAY", "MAYA"]
      assert alley.cast == ["MAYA"]
    end

    test "measures scenes in eighths of a page, at least one" do
      [vault, _] = Stats.scenes(@script)
      assert vault.eighths >= 1
      assert Stats.scenes("INT. A - DAY") |> hd() |> Map.get(:eighths) == 1
    end

    test "gives each scene a one-line synopsis" do
      [vault, alley] = Stats.scenes(@script)
      assert vault.synopsis == "RAY cracks the safe with a crowbar. Gunther watches."
      assert alley.synopsis == "A getaway van idles. The gun lies in a puddle."

      [scene] =
        Stats.scenes("INT. A - DAY\n\n= The heist goes wrong\n\n#{String.duplicate("x", 200)}")

      assert scene.synopsis == "The heist goes wrong"
      [long] = Stats.scenes("INT. A - DAY\n\n#{String.duplicate("x", 200)}")
      assert String.length(long.synopsis) == 90
      assert Stats.scenes("INT. A - DAY") |> hd() |> Map.get(:synopsis) == nil
    end

    test "is empty for a script without scenes" do
      assert Stats.scenes("Just some action.") == []
      assert Stats.scenes(nil) == []
    end
  end

  describe "locate/2" do
    setup do
      lines = @script |> String.split("\n") |> Enum.map(&" #{Breakdown.normalize(&1)} ")
      %{lines: List.to_tuple(lines)}
    end

    test "keeps the recorded line while the words are still on it", %{lines: lines} do
      assert Breakdown.locate(lines, %{anchor_text: "crowbar", line_no: 5}) == 5
    end

    test "follows the words to the nearest line after edits move them", %{lines: lines} do
      assert Breakdown.locate(lines, %{anchor_text: "the gun", line_no: 17}) == 15
      assert Breakdown.locate(lines, %{anchor_text: "the gun", line_no: 9}) == 8
    end

    test "matches whole words only", %{lines: lines} do
      assert Breakdown.locate(lines, %{anchor_text: "gunth", line_no: 5}) == nil
      assert Breakdown.locate(lines, %{anchor_text: "gunther", line_no: 0}) == 5
    end

    test "is nil when the words are gone", %{lines: lines} do
      assert Breakdown.locate(lines, %{anchor_text: "helicopter", line_no: 5}) == nil
    end

    test "keeps the line for a tag with no words, if it still exists", %{lines: lines} do
      assert Breakdown.locate(lines, %{anchor_text: nil, line_no: 13}) == 13
      assert Breakdown.locate(lines, %{anchor_text: "", line_no: 900}) == nil
    end
  end

  describe "fit_anchor/3" do
    test "keeps a selection that is on the line, ignoring markup" do
      assert Breakdown.fit_anchor(@script, 5, "crowbar") == "crowbar"
      assert Breakdown.fit_anchor(@script, 5, "a crowbar.") == "a crowbar."
    end

    test "trims a selection that runs past the line" do
      assert Breakdown.fit_anchor(@script, 5, "Gunther watches. RAY Hand me") ==
               "Gunther watches."
    end

    test "is nil when nothing selected is on the line" do
      assert Breakdown.fit_anchor(@script, 5, "helicopter") == nil
      assert Breakdown.fit_anchor(@script, 999, "crowbar") == nil
    end
  end

  describe "build/2" do
    test "places tags in their scenes and reports lost ones as unplaced" do
      crowbar = tag(%{category: "props", name: "Crowbar", anchor_text: "crowbar", line_no: 5})

      van =
        tag(%{category: "vehicles", name: "Getaway van", anchor_text: "getaway van", line_no: 15})

      gone = tag(%{category: "props", name: "Map", anchor_text: "treasure map", line_no: 5})

      %{scenes: [vault, alley], unplaced: unplaced} =
        Breakdown.build(@script, [crowbar, van, gone])

      assert [%{name: "Crowbar", auto: false}] = vault.elements["props"]
      assert [%{name: "Getaway van"}] = alley.elements["vehicles"]
      refute Map.has_key?(alley.elements, "props")
      assert unplaced == [gone]
    end

    test "seeds cast from speaking parts and merges tagged cast into them" do
      ray = tag(%{category: "cast", name: "ray", anchor_text: "RAY cracks", line_no: 5})
      gunther = tag(%{category: "cast", name: "Gunther", anchor_text: "Gunther", line_no: 5})

      %{scenes: [vault, _]} = Breakdown.build(@script, [ray, gunther])

      assert [
               %{name: "GUNTHER", auto: false, tags: [^gunther]},
               %{name: "MAYA", auto: true, tags: []},
               %{name: "RAY", auto: true, tags: [^ray]}
             ] = vault.elements["cast"]
    end

    test "treats names differing only in case or punctuation as one element" do
      a = tag(%{category: "props", name: "Gun", anchor_text: "gun", line_no: 8})
      b = tag(%{category: "props", name: "gun.", anchor_text: "gun", line_no: 15})
      c = tag(%{category: "props", name: "GUN", anchor_text: "gun", line_no: 8})

      %{scenes: [vault, alley]} = Breakdown.build(@script, [a, b, c])
      assert [%{key: "gun", tags: tags}] = vault.elements["props"]
      assert length(tags) == 2
      assert [%{key: "gun"}] = alley.elements["props"]
    end
  end

  describe "departments/1" do
    test "lists each element with its scenes, most used first" do
      gun1 = tag(%{category: "props", name: "Gun", anchor_text: "gun", line_no: 8})
      gun2 = tag(%{category: "props", name: "Gun", anchor_text: "gun", line_no: 15})
      bar = tag(%{category: "props", name: "Crowbar", anchor_text: "crowbar", line_no: 5})

      depts =
        @script |> Breakdown.build([gun1, gun2, bar]) |> Breakdown.departments() |> Map.new()

      assert [%{name: "Gun", scenes: [1, 2]}, %{name: "Crowbar", scenes: [1]}] = depts["props"]
      assert [%{name: "MAYA", scenes: [1, 2]}, %{name: "RAY", scenes: [1]}] = depts["cast"]
      assert depts["vfx"] == []
    end
  end

  describe "to_csv/1" do
    defp csv(text, tags),
      do: text |> Breakdown.build(tags) |> Breakdown.to_csv() |> IO.iodata_to_binary()

    test "one row per element per scene, and a row for empty scenes" do
      van =
        tag(%{category: "vehicles", name: "Getaway van", anchor_text: "getaway van", line_no: 15})

      [header | rows] = @script |> csv([van]) |> String.split("\r\n", trim: true)

      assert header == "Scene,Heading,INT/EXT,Time,Pages (eighths),Category,Element"
      assert "1,INT. BANK VAULT - NIGHT,INT,NIGHT,2,Cast,MAYA" in rows
      assert "2,EXT. ALLEY - DAY,EXT,DAY,2,Vehicles,Getaway van" in rows
      assert csv("INT. EMPTY ROOM\n\nSilence.", []) =~ "1,INT. EMPTY ROOM,INT,,1,,\r\n"
    end

    test "quotes awkward cells and defuses formulas" do
      tricky =
        tag(%{category: "props", name: ~s(Sign, "WET"), anchor_text: "crowbar", line_no: 5})

      formula =
        tag(%{category: "props", name: "=HYPERLINK(1)", anchor_text: "crowbar", line_no: 5})

      out = csv(@script, [tricky, formula])

      assert out =~ ~s(,Props,"Sign, ""WET"""\r\n)
      assert out =~ ",Props,'=HYPERLINK(1)\r\n"
    end
  end
end
