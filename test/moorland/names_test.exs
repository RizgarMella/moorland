defmodule Moorland.Scripts.NamesTest do
  use ExUnit.Case, async: true

  alias Moorland.Scripts.Names

  @story """
  # Chapter One

  When Anna Grey reached the lighthouse, Thessaly Marchbanks was waiting.
  "The lamp," said Marchbanks. She pointed. Anna's coat was wet.
  The keeper, Dr. Okafor, had gone to Penzance on Tuesday.
  when the tide turned, Anna Grey left. Dr. Okafor waved.
  I watched them go. Then she told Marchbanks everything.
  NASA was not involved. OK.

  /* Cut: Bartholomew stayed behind. */
  """

  test "finds names and leaves out what only looks like one" do
    names = Names.harvest(@story) |> Enum.map(& &1.name)

    for name <- ~w(Anna Marchbanks Okafor Thessaly Grey Penzance Tuesday),
        do: assert(name in names)

    for word <- ~w(When The She Then I Chapter One NASA OK Dr Bartholomew),
        do: refute(word in names)

    assert "Anna Grey" in names and "Dr. Okafor" in names
    refute "Thessaly Marchbanks" in names
    assert hd(Names.harvest(@story)) == %{name: "Anna", count: 3}
  end

  test "lower-case use disqualifies, and empty text has none" do
    assert Names.harvest("Rain fell. They watched the rain. Then Rain came.") == []
    assert Names.harvest(nil) == []
  end
end
