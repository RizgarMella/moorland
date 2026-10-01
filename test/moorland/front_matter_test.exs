defmodule Moorland.Scripts.FrontMatterTest do
  use ExUnit.Case, async: true

  alias Moorland.Scripts.{FrontMatter, Names, ProseExport, Stats}

  @story """
  ---
  title: The Keeper
  Author: R. Mella
  contact: r@example.com
  dedication: For my *father*
  epigraph:
  ---

  # One

  Anna walked. Later Anna slept.
  """

  test "reads the block and blanks it, keeping line numbers" do
    {fields, body} = FrontMatter.split(@story)

    assert fields == %{
             "title" => "The Keeper",
             "author" => "R. Mella",
             "contact" => "r@example.com",
             "dedication" => "For my *father*"
           }

    assert String.split(body, "\n") |> Enum.take(9) == ["", "", "", "", "", "", "", "", "# One"]
  end

  test "no block, or an unclosed one, is no front matter" do
    assert FrontMatter.split("# One\n\nText.") == {%{}, "# One\n\nText."}
    assert {%{}, _} = FrontMatter.split("---\ntitle: Never closed\n\nText.")
    assert FrontMatter.split(nil) == {%{}, ""}
  end

  test "front matter is not counted or mistaken for names" do
    assert Stats.compute_prose(@story).words == 6
    names = Names.harvest(@story) |> Enum.map(& &1.name)
    assert "Anna" in names
    refute "Keeper" in names or "Mella" in names
  end

  test "exports use it: title page, dedication page, EPUB title page" do
    {:ok, files} =
      @story
      |> ProseExport.docx(%{title: "Untitled", author: "someone", contact: "x"})
      |> :zip.unzip([:memory])

    doc = files |> Enum.find(fn {n, _} -> n == ~c"word/document.xml" end) |> elem(1)
    assert doc =~ "THE KEEPER" and doc =~ "by R. Mella" and doc =~ "r@example.com"
    assert doc =~ "father"
    refute doc =~ "Untitled"

    {:ok, files} =
      @story
      |> ProseExport.epub(%{title: "Untitled", author: "someone", uid: "u"})
      |> :zip.unzip([:memory])

    names = Enum.map(files, &to_string(elem(&1, 0)))
    assert "OEBPS/title.xhtml" in names
    title = files |> Enum.find(fn {n, _} -> n == ~c"OEBPS/title.xhtml" end) |> elem(1)
    assert title =~ "The Keeper" and title =~ "<em>father</em>"
    {_doc, _} = :xmerl_scan.string(String.to_charlist(title), quiet: true)
  end
end
