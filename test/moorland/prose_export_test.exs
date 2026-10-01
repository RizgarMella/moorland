defmodule Moorland.Scripts.ProseExportTest do
  use ExUnit.Case, async: true

  alias Moorland.Scripts.ProseExport

  @story """
  # The Lamp

  ## Night

  Anna climbed the *iron* stairs.
  The lamp was **out** & cold.

  ***

  > A line remembered <here>.

  # The Sea

  Morning came _grey_.

  /* cut */
  """

  defp unzip(binary) do
    {:ok, files} = :zip.unzip(binary, [:memory])
    Map.new(files, fn {name, data} -> {to_string(name), data} end)
  end

  defp well_formed!(xml) do
    {_doc, _rest} = :xmerl_scan.string(String.to_charlist(xml), quiet: true)
    :ok
  end

  test "blocks and inline runs" do
    assert [
             {:heading, 1, "The Lamp"},
             {:heading, 2, "Night"},
             {:para, "Anna climbed the *iron* stairs. The lamp was **out** & cold."},
             :break,
             {:quote, "A line remembered <here>."},
             {:heading, 1, "The Sea"},
             {:para, "Morning came _grey_."}
           ] = ProseExport.blocks(@story)

    assert [
             {"a ", %{italic: false}},
             {"b", %{italic: true}},
             {" ", _},
             {"c", %{bold: true}},
             {" ", _},
             {"d", %{underline: true}}
           ] =
             ProseExport.runs("a *b* **c** _d_")
  end

  test "word counts round the way a title page does" do
    assert ProseExport.rounded_words(42) == 42
    assert ProseExport.rounded_words(1_249) == 1_200
    assert ProseExport.rounded_words(84_600) == 85_000
  end

  test "the .docx is a well-formed manuscript" do
    files =
      @story
      |> ProseExport.docx(%{title: "The Keeper", author: "Riz", contact: "riz@example.com"})
      |> unzip()

    assert Map.keys(files) |> Enum.sort() ==
             ~w([Content_Types].xml _rels/.rels docProps/core.xml word/_rels/document.xml.rels word/document.xml word/styles.xml)

    Enum.each(files, fn {_name, xml} -> well_formed!(xml) end)
    doc = files["word/document.xml"]
    assert doc =~ "THE KEEPER" and doc =~ "by Riz" and doc =~ "about 22 words"
    assert doc =~ ~s(<w:pStyle w:val="Heading1"/>)
    assert doc =~ ~s(<w:i/></w:rPr><w:t xml:space="preserve">iron)
    assert doc =~ "&amp; cold" and doc =~ "&lt;here&gt;"
    refute doc =~ "cut"
    assert files["word/styles.xml"] =~ ~s(w:line="480")
  end

  test "the .epub has its mimetype first and stored, and a chapter each" do
    epub = ProseExport.epub(@story, %{title: "The Keeper", author: "Riz", uid: "abc"})

    # Zip local header: name at offset 30, compression method (0 = stored) at 8.
    assert binary_part(epub, 30, 8) == "mimetype"
    assert binary_part(epub, 8, 2) == <<0, 0>>

    files = unzip(epub)
    assert files["mimetype"] == "application/epub+zip"

    assert Map.has_key?(files, "OEBPS/chapter-1.xhtml") and
             Map.has_key?(files, "OEBPS/chapter-2.xhtml")

    for {name, data} <- files,
        String.ends_with?(name, [".xml", ".xhtml", ".opf"]),
        do: well_formed!(data)

    assert files["OEBPS/nav.xhtml"] =~ "The Lamp" and files["OEBPS/nav.xhtml"] =~ "The Sea"
    assert files["OEBPS/chapter-1.xhtml"] =~ "<em>iron</em>"
    assert files["OEBPS/chapter-2.xhtml"] =~ "<u>grey</u>"
  end

  test "a story without chapters is one chapter" do
    files =
      "Just a paragraph." |> ProseExport.epub(%{title: "T", author: "A", uid: "x"}) |> unzip()

    assert Map.has_key?(files, "OEBPS/chapter-1.xhtml")
    refute Map.has_key?(files, "OEBPS/chapter-2.xhtml")
  end
end
