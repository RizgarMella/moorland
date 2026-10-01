defmodule Moorland.Scripts.ProseExport do
  @moduledoc """
  Prose out of Moorland as Word (.docx) and EPUB, built by hand and zipped
  with Erlang's `:zip`, so no dependency comes with them.

  The Word file is a standard manuscript: a title page (contact top left,
  word count top right, title and byline centred), then 12pt Times, double
  spaced, half-inch first-line indents, each chapter on a new page, scene
  breaks as a centred `#`. The EPUB has one XHTML file per chapter and a
  table of contents.
  """

  ## Markdown, as prose.js reads it

  @doc "Blocks: `{:heading, level, text}`, `:break`, `{:quote, text}`, `{:para, text}`."
  def blocks(text) do
    text
    |> Moorland.Scripts.FrontMatter.body()
    |> String.replace(~r/\/\*[\s\S]*?\*\//, "")
    |> String.split("\n")
    |> Enum.chunk_while(
      nil,
      fn raw, para ->
        line = String.trim_trailing(raw)

        cond do
          String.trim(line) == "" ->
            emit(para, nil)

          m = Regex.run(~r/^(\#{1,3})\s+(.*)$/, line) ->
            [_, hashes, title] = m
            emit(para, {:heading, String.length(hashes), String.trim(title)}, :flush)

          Regex.match?(~r/^\s*(([*\-_])\s*){3,}$/, line) ->
            emit(para, :break, :flush)

          String.starts_with?(line, ">") ->
            body = String.replace(line, ~r/^>\s?/, "")

            case para do
              {:quote, t} -> {:cont, {:quote, t <> " " <> body}}
              _ -> emit(para, {:quote, body})
            end

          true ->
            case para do
              {:para, t} -> {:cont, {:para, t <> " " <> String.trim(line)}}
              _ -> emit(para, {:para, String.trim(line)})
            end
        end
      end,
      fn
        nil -> {:cont, nil}
        para -> {:cont, para, nil}
      end
    )
    |> List.flatten()
  end

  # Emits the open paragraph (if any) and starts `next`; a heading or break
  # is emitted at once rather than held open.
  defp emit(nil, next), do: {:cont, next}
  defp emit(para, next), do: {:cont, para, next}
  defp emit(nil, block, :flush), do: {:cont, [block], nil}
  defp emit(para, block, :flush), do: {:cont, [para, block], nil}

  @doc "Inline runs: `[{text, %{bold, italic, underline}}]` from `*`, `**`, `***` and `_`."
  def runs(text) do
    ~r/(\*\*\*[^*]+\*\*\*|\*\*[^*]+\*\*|\*[^*]+\*|_[^_]+_)/
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn
      "***" <> rest ->
        {String.trim_trailing(rest, "***"), %{bold: true, italic: true, underline: false}}

      "**" <> rest ->
        {String.trim_trailing(rest, "**"), %{bold: true, italic: false, underline: false}}

      "*" <> rest = t when byte_size(t) > 2 ->
        {String.trim_trailing(rest, "*"), %{bold: false, italic: true, underline: false}}

      "_" <> rest = t when byte_size(t) > 2 ->
        {String.trim_trailing(rest, "_"), %{bold: false, italic: false, underline: true}}

      plain ->
        {plain, %{bold: false, italic: false, underline: false}}
    end)
  end

  defp words(text) do
    text
    |> blocks()
    |> Enum.map(fn
      {_kind, _level, t} -> t
      {_kind, t} -> t
      :break -> ""
    end)
    |> Enum.map(fn t ->
      t
      |> String.replace(~r/[*_]+/, " ")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.count(&Regex.match?(~r/[\p{L}\p{N}]/u, &1))
    end)
    |> Enum.sum()
  end

  @doc "Word counts are rounded on a manuscript title page: to the nearest 100, or 1,000 past 10,000."
  def rounded_words(n) when n >= 10_000, do: round(n / 1000) * 1000
  def rounded_words(n) when n >= 100, do: round(n / 100) * 100
  def rounded_words(n), do: n

  defp esc(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp grouped(n), do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+$)/, ",")

  ## Word

  # Front matter in the text overrides what the caller guessed.
  defp with_front_matter(text, meta) do
    {fields, _body} = Moorland.Scripts.FrontMatter.split(text)

    meta
    |> Map.merge(
      Map.take(fields, ~w(title author contact))
      |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
    )
    |> Map.put(:dedication, fields["dedication"])
    |> Map.put(:epigraph, fields["epigraph"])
  end

  @doc "A .docx as a binary. `meta`: `%{title, author, contact}`; front matter in the text wins."
  def docx(text, meta) do
    meta = with_front_matter(text, meta)

    files = [
      {~c"[Content_Types].xml", content_types()},
      {~c"_rels/.rels", rels()},
      {~c"word/document.xml", document(text, meta)},
      # Without this the document never finds its styles.
      {~c"word/_rels/document.xml.rels", document_rels()},
      {~c"word/styles.xml", styles()},
      {~c"docProps/core.xml", core(meta)}
    ]

    {:ok, {_name, zip}} = :zip.create(~c"manuscript.docx", files, [:memory])
    zip
  end

  defp content_types do
    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
</Types>)
  end

  defp rels do
    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
</Relationships>)
  end

  defp document_rels do
    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>)
  end

  defp core(meta) do
    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title>#{esc(meta.title)}</dc:title>
<dc:creator>#{esc(meta.author)}</dc:creator>
</cp:coreProperties>)
  end

  # Manuscript styles: everything 12pt Times, double spaced (line 480).
  defp styles do
    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:docDefaults>
<w:rPrDefault><w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:rPrDefault>
<w:pPrDefault><w:pPr><w:spacing w:before="0" w:after="0" w:line="480" w:lineRule="auto"/></w:pPr></w:pPrDefault>
</w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:pPr><w:ind w:firstLine="720"/></w:pPr></w:style>
<w:style w:type="paragraph" w:styleId="NoIndent"><w:name w:val="No Indent"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:firstLine="0"/></w:pPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="NoIndent"/><w:pPr><w:pageBreakBefore/><w:spacing w:before="2880" w:after="480"/><w:ind w:firstLine="0"/><w:jc w:val="center"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:caps/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="NoIndent"/><w:pPr><w:spacing w:before="240"/><w:ind w:firstLine="0"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="NoIndent"/><w:pPr><w:ind w:firstLine="0"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:i/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="SceneBreak"><w:name w:val="Scene Break"/><w:basedOn w:val="Normal"/><w:next w:val="NoIndent"/><w:pPr><w:ind w:firstLine="0"/><w:jc w:val="center"/></w:pPr></w:style>
<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="720" w:right="720" w:firstLine="0"/></w:pPr><w:rPr><w:i/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="TitlePage"><w:name w:val="Title Page"/><w:basedOn w:val="NoIndent"/><w:pPr><w:spacing w:line="240" w:lineRule="auto"/></w:pPr></w:style>
</w:styles>)
  end

  defp document(text, meta) do
    word_count = text |> words() |> rounded_words()

    title_page = [
      tabbed(meta.author, "about #{grouped(word_count)} words"),
      para("TitlePage", [{meta.contact, plain()}]),
      ~s(<w:p><w:pPr><w:pStyle w:val="TitlePage"/><w:spacing w:before="4320"/><w:jc w:val="center"/></w:pPr>#{run(String.upcase(meta.title), plain())}</w:p>),
      ~s(<w:p><w:pPr><w:pStyle w:val="TitlePage"/><w:spacing w:before="240"/><w:jc w:val="center"/></w:pPr>#{run("by " <> meta.author, plain())}</w:p>)
    ]

    {body, _} =
      text
      |> blocks()
      |> Enum.map_reduce(:start, fn
        {:heading, level, t}, _ -> {para("Heading#{level}", runs(t)), :after_heading}
        :break, _ -> {para("SceneBreak", [{"#", plain()}]), :after_heading}
        {:quote, t}, _ -> {para("Quote", runs(t)), :after_heading}
        {:para, t}, :body -> {para("Normal", runs(t)), :body}
        {:para, t}, _ -> {para("NoIndent", runs(t)), :body}
      end)

    # Without a first chapter heading, the text still starts on a new page.
    body =
      case blocks(text) do
        [{:heading, 1, _} | _] -> body
        _ -> [~s(<w:p><w:r><w:br w:type="page"/></w:r></w:p>) | body]
      end

    # Dedication and epigraph each get a page of their own, set a third of
    # the way down, centred and single-spaced.
    extra_pages =
      for value <- [meta[:dedication], meta[:epigraph]], value do
        ~s(<w:p><w:pPr><w:pStyle w:val="TitlePage"/><w:pageBreakBefore/><w:spacing w:before="4320"/><w:jc w:val="center"/></w:pPr>#{Enum.map_join(runs(value), "", fn {t, f} -> run(t, %{f | italic: true}) end)}</w:p>)
      end

    ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
#{Enum.join(title_page ++ extra_pages ++ body, "\n")}
<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
</w:body></w:document>)
  end

  defp plain, do: %{bold: false, italic: false, underline: false}

  defp tabbed(left, right) do
    ~s(<w:p><w:pPr><w:pStyle w:val="TitlePage"/><w:tabs><w:tab w:val="right" w:pos="9360"/></w:tabs></w:pPr>#{run(left, plain())}<w:r><w:tab/></w:r>#{run(right, plain())}</w:p>)
  end

  defp para(style, runs) do
    ~s(<w:p><w:pPr><w:pStyle w:val="#{style}"/></w:pPr>#{Enum.map_join(runs, "", fn {t, f} -> run(t, f) end)}</w:p>)
  end

  defp run(text, f) do
    props =
      [f.bold && "<w:b/>", f.italic && "<w:i/>", f.underline && ~s(<w:u w:val="single"/>)]
      |> Enum.filter(& &1)
      |> Enum.join()

    props = if props == "", do: "", else: "<w:rPr>#{props}</w:rPr>"
    ~s(<w:r>#{props}<w:t xml:space="preserve">#{esc(text)}</w:t></w:r>)
  end

  ## EPUB

  @doc "An EPUB 3 as a binary. `meta`: `%{title, author, uid}`; front matter in the text wins."
  def epub(text, meta) do
    meta = text |> with_front_matter(Map.put_new(meta, :contact, nil))
    chapters = chapters(text)

    files =
      [
        {~c"mimetype", "application/epub+zip"},
        {~c"META-INF/container.xml", container()},
        {~c"OEBPS/content.opf", opf(meta, chapters)},
        {~c"OEBPS/nav.xhtml", nav(meta, chapters)},
        {~c"OEBPS/style.css", css()},
        {~c"OEBPS/title.xhtml", title_xhtml(meta)}
      ] ++
        for {chapter, i} <- Enum.with_index(chapters, 1) do
          {String.to_charlist("OEBPS/chapter-#{i}.xhtml"), chapter_xhtml(chapter, meta)}
        end

    # The mimetype must come first and be stored, not compressed.
    {:ok, {_name, zip}} = :zip.create(~c"book.epub", files, [:memory, {:uncompress, [~c""]}])
    zip
  end

  # [%{title, blocks}]: split at chapter (#) headings.
  defp chapters(text) do
    text
    |> blocks()
    |> Enum.chunk_while(
      nil,
      fn
        {:heading, 1, t}, nil -> {:cont, %{title: t, blocks: []}}
        {:heading, 1, t}, ch -> {:cont, finish(ch), %{title: t, blocks: []}}
        block, nil -> {:cont, %{title: nil, blocks: [block]}}
        block, ch -> {:cont, %{ch | blocks: [block | ch.blocks]}}
      end,
      fn
        nil -> {:cont, nil}
        ch -> {:cont, finish(ch), nil}
      end
    )
    |> Enum.with_index(1)
    |> Enum.map(fn {ch, i} -> %{ch | title: ch.title || "Chapter #{i}"} end)
    |> case do
      [] -> [%{title: "Chapter 1", blocks: []}]
      chapters -> chapters
    end
  end

  defp finish(ch), do: %{ch | blocks: Enum.reverse(ch.blocks)}

  defp container do
    ~s(<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>)
  end

  defp opf(meta, chapters) do
    items =
      [~s(<item id="title" href="title.xhtml" media-type="application/xhtml+xml"/>)] ++
        for i <- 1..length(chapters) do
          ~s(<item id="ch#{i}" href="chapter-#{i}.xhtml" media-type="application/xhtml+xml"/>)
        end

    spine = [
      ~s(<itemref idref="title"/>)
      | for(i <- 1..length(chapters), do: ~s(<itemref idref="ch#{i}"/>))
    ]

    modified = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    ~s(<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="book-id">urn:uuid:#{esc(meta.uid)}</dc:identifier>
<dc:title>#{esc(meta.title)}</dc:title>
<dc:creator>#{esc(meta.author)}</dc:creator>
<dc:language>en</dc:language>
<meta property="dcterms:modified">#{modified}</meta>
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="css" href="style.css" media-type="text/css"/>
#{Enum.join(items, "\n")}
</manifest>
<spine>
#{Enum.join(spine, "\n")}
</spine>
</package>)
  end

  defp nav(meta, chapters) do
    links =
      for {ch, i} <- Enum.with_index(chapters, 1),
          do: ~s(<li><a href="chapter-#{i}.xhtml">#{esc(ch.title)}</a></li>)

    xhtml(
      meta.title,
      ~s(<nav epub:type="toc" id="toc"><h1>Contents</h1><ol>#{Enum.join(links)}</ol></nav>)
    )
  end

  defp title_xhtml(meta) do
    extra =
      for {value, class} <- [{meta[:dedication], "dedication"}, {meta[:epigraph], "epigraph"}],
          value do
        ~s(<p class="#{class}">#{inline(value)}</p>)
      end

    xhtml(
      meta.title,
      ~s(<section class="title-page"><h1>#{esc(meta.title)}</h1><p class="byline">#{esc(meta.author)}</p>#{Enum.join(extra)}</section>)
    )
  end

  defp chapter_xhtml(chapter, _meta) do
    body =
      Enum.map_join(chapter.blocks, "\n", fn
        {:heading, level, t} -> "<h#{level + 1}>#{inline(t)}</h#{level + 1}>"
        :break -> ~s(<p class="break">*&#160;&#160;*&#160;&#160;*</p>)
        {:quote, t} -> "<blockquote><p>#{inline(t)}</p></blockquote>"
        {:para, t} -> "<p>#{inline(t)}</p>"
      end)

    xhtml(chapter.title, "<h1>#{esc(chapter.title)}</h1>\n" <> body)
  end

  defp inline(text) do
    Enum.map_join(runs(text), fn {t, f} ->
      t = esc(t)
      t = if f.underline, do: "<u>#{t}</u>", else: t
      t = if f.italic, do: "<em>#{t}</em>", else: t
      if f.bold, do: "<strong>#{t}</strong>", else: t
    end)
  end

  defp xhtml(title, body) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
<head><meta charset="UTF-8"/><title>#{esc(title)}</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body>
#{body}
</body>
</html>)
  end

  defp css do
    """
    body { font-family: serif; line-height: 1.5; }
    h1 { text-align: center; margin: 3em 0 1.5em; }
    p { margin: 0; text-indent: 1.5em; }
    h1 + p, h2 + p, h3 + p, p.break + p, blockquote + p { text-indent: 0; }
    p.break { text-align: center; margin: 1em 0; text-indent: 0; }
    blockquote { margin: 1em 2em; font-style: italic; }
    .title-page { text-align: center; margin-top: 30%; }
    .title-page p { text-indent: 0; }
    .byline { margin-top: 1em; }
    .dedication, .epigraph { font-style: italic; margin-top: 3em; }
    """
  end
end
