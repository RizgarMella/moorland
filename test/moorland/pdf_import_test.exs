defmodule Moorland.Scripts.PdfImportTest do
  use ExUnit.Case, async: true

  alias Moorland.Pdf
  alias Moorland.Scripts.{PdfImport, Stats}

  # Printed from Moorland itself by Chromium: CID fonts, ToUnicode maps,
  # flipped and scaled coordinates, Flate-compressed streams.
  @pdf File.read!("test/fixtures/screenplay.pdf")
  @source File.read!("test/fixtures/screenplay.fountain")

  # A PDF the old-fashioned way: a standard Courier font, WinAnsi bytes,
  # uncompressed, lines placed with Td. 72pt margin, 7.2pt per character.
  defp simple_pdf(lines) do
    body =
      lines
      |> Enum.map_join("\n", fn {indent, y, text} ->
        "BT /F1 12 Tf #{72 + indent * 7.2} #{y} Td (#{String.replace(text, ~r/([()\\\\])/, "\\\\\\1")}) Tj ET"
      end)

    objs = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
      "<< /Length #{byte_size(body)} >>\nstream\n#{body}\nendstream",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>"
    ]

    numbered =
      objs
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {o, i} -> "#{i} 0 obj\n#{o}\nendobj" end)

    "%PDF-1.4\n" <> numbered <> "\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n"
  end

  test "reads positioned text out of a real PDF" do
    {:ok, pages} = Pdf.text_runs(@pdf)
    assert length(pages) == 7
    assert Enum.any?(hd(pages), &(&1.text == "THE LAMP"))
    run = pages |> Enum.at(1) |> Enum.find(&(&1.text == "TOM (O.S.)"))
    assert_in_delta run.x, 248.4, 0.5
    assert_in_delta run.size, 12, 0.1
  end

  test "melts a printed script back into the same Fountain" do
    {:ok, text} = PdfImport.to_fountain(@pdf)
    a = Stats.compute(@source)
    b = Stats.compute(text)

    assert b.scene_count == a.scene_count

    assert Enum.map(b.characters, &{&1.name, &1.lines}) ==
             Enum.map(a.characters, &{&1.name, &1.lines})

    assert b.words == a.words

    assert text =~ "Title: THE LAMP\nCredit: Written by\nAuthor: R. Mella\nContact: r@example.com"
    assert text =~ "ANNA\nTwo hundred and twelve.\n(beat)\nAlways two hundred and twelve."
    assert text =~ "\nCUT TO:\n"
    assert text =~ "The lamp turns. ANNA (30s, salt-worn) climbs the iron stairs, counting."
    refute text =~ ~r/^\d+\.$/m
  end

  test "classifies by indent: headings, speech, parentheticals, transitions, CONT'D" do
    pdf =
      simple_pdf([
        {0, 700, "12 INT. ATTIC - NIGHT 12"},
        {0, 672, "Dust everywhere."},
        {22, 644, "NORA"},
        {16, 630, "(whispering)"},
        {10, 616, "Who's there?"},
        {10, 602, "Hello?"},
        {22, 560, "NORA (CONT'D)"},
        {10, 546, "Anyone?"},
        {48, 518, "SMASH CUT TO:"},
        {0, 490, "BANG!"},
        {66, 760, "2."}
      ])

    {:ok, text} = PdfImport.to_fountain(pdf)

    assert text =~ "INT. ATTIC - NIGHT #12#"
    assert text =~ "NORA\n(whispering)\nWho's there? Hello? Anyone?"
    assert text =~ "SMASH CUT TO:"
    assert text =~ "!BANG!"
    refute text =~ "2."
  end

  test "says why it could not" do
    assert {:error, :not_pdf} = PdfImport.to_fountain("hello")
    assert {:error, :encrypted} = PdfImport.to_fountain("%PDF-1.4\n<< /Encrypt 5 0 R >>")
    assert {:error, _} = PdfImport.to_fountain(simple_pdf([]))
    assert {:error, _} = PdfImport.to_fountain("%PDF-1.4 garbage")
  end
end
