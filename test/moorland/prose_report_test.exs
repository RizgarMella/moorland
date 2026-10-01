defmodule Moorland.Scripts.ProseReportTest do
  use ExUnit.Case, async: true

  alias Moorland.Scripts.ProseReport

  @story """
  A short opening line.

  # The Lamp

  The lamp turned slowly. The lamp was broken. The lamp, the lamp, the lamp.
  "Go," Anna said quickly. "Now," she hissed. "Why?" he asked. "Because," she hissed.

  /* The door was opened carefully by the keeper. */

  # The Sea

  The boat was taken by the tide, and only the early light remained. She was tired.
  """

  test "chapters with words and reading time" do
    assert [
             %{title: "Opening", line: 0, words: 4, minutes: 1},
             %{title: "The Lamp", line: 2, words: words},
             %{title: "The Sea", line: 9}
           ] = ProseReport.analyze(@story).chapters

    assert words > 20
  end

  test "echoes are frequent words within a paragraph" do
    assert [%{word: "lamp", count: 5, line: 4}] = ProseReport.analyze(@story).echoes
  end

  test "adverbs skip -ly words that aren't" do
    adverbs = ProseReport.analyze(@story).adverbs
    words = Enum.map(adverbs.top, & &1.word)
    assert "slowly" in words and "quickly" in words
    refute "only" in words or "early" in words
    # The boneyard does not count.
    refute "carefully" in words
  end

  test "passive voice: be plus a participle" do
    passive = ProseReport.analyze(@story).passive
    phrases = Enum.map(passive.examples, & &1.phrase)
    assert "was broken" in phrases and "was taken" in phrases and "was tired" in phrases
    refute Enum.any?(phrases, &(&1 =~ "opened"))
    assert passive.count == 3
  end

  test "dialogue tags: plain against showy" do
    assert %{plain: 2, showy: [{"hissed", 2}]} = ProseReport.analyze(@story).tags
  end

  test "an empty story has nothing to report" do
    assert %{chapters: [], echoes: [], adverbs: %{count: 0}, passive: %{count: 0}} =
             ProseReport.analyze("")
  end
end
