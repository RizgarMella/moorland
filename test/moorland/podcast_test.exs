defmodule Moorland.Scripts.PodcastTest do
  use ExUnit.Case, async: true

  alias Moorland.Scripts.{Script, Stats}

  test "lengths are read as written" do
    assert Stats.parse_duration("1:30") == 90
    assert Stats.parse_duration(" 45s ") == 45
    assert Stats.parse_duration("2 min") == 120
    assert Stats.parse_duration("90 seconds") == 90
    assert Stats.parse_duration("about a minute") == nil
    assert Stats.parse_duration("1:75") == nil
  end

  test "segments are timed by speech, or by their written length when silent" do
    words = fn n -> Enum.map_join(1..n, " ", fn _ -> "word" end) end

    text = """
    HOST
    #{words.(15)}

    # Interview
    = 5:00

    HOST
    #{words.(150)}

    GUEST
    #{words.(75)}

    SFX: a door creaks open slowly behind them

    # Ad break
    = 1:00

    # Music bed
    """

    stats = Stats.compute_podcast(text)

    assert [
             %{title: "Opening", words: 15, seconds: 6},
             %{title: "Interview", words: 225, seconds: 90, target: 300},
             %{title: "Ad break", words: 0, seconds: 60, target: 60},
             %{title: "Music bed", seconds: 0, target: nil}
           ] = stats.segments

    assert stats.seconds == 156
    assert stats.minutes == 3
    assert Enum.map(stats.characters, & &1.name) == ["HOST", "GUEST"]
    assert stats.podcast
  end

  test "the template is a podcast with segments and hosts" do
    stats = Stats.compute_podcast(Script.template("podcast"))

    assert Enum.map(stats.segments, & &1.title) == [
             "Cold open",
             "Intro",
             "Segment one",
             "Ad break",
             "Outro"
           ]

    assert Enum.map(stats.characters, & &1.name) |> Enum.sort() == ["GUEST", "HOST"]
    assert Script.template("screenplay") == ""
  end
end
