defmodule Moorland.Pdf do
  @moduledoc """
  A small PDF reader, enough to get the text out of a screenplay with where
  each piece sits on the page. No dependency: Erlang's `:zlib` inflates the
  streams.

  `text_runs/1` returns, per page, the runs of text drawn on it:
  `%{x, y, end_x, size, text}` in PDF points with the origin at the bottom
  left. It follows object streams, the page tree (with inherited
  resources), form XObjects, the text and graphics state needed for
  positions, glyph widths for where a run ends, and ToUnicode maps or
  standard encodings for what the glyphs say. Encrypted PDFs, and fonts
  that give no way back to characters, are reported as unreadable.
  """

  import Bitwise

  ## Entry point

  def text_runs(binary) when is_binary(binary) do
    cond do
      not String.starts_with?(binary, "%PDF") ->
        {:error, :not_pdf}

      Regex.match?(~r/\/Encrypt\s/, binary) ->
        {:error, :encrypted}

      true ->
        objects = objects(binary)
        pages = pages(objects, binary)

        if pages == [] do
          {:error, :no_pages}
        else
          {:ok, Enum.map(pages, &page_runs(&1, objects))}
        end
    end
  rescue
    _ -> {:error, :unreadable}
  end

  ## Objects

  # %{id => value}; stream objects are {:stream, dict, decoded_bytes}.
  defp objects(binary) do
    direct =
      ~r/(\d+)\s+(\d+)\s+obj\b/
      |> Regex.scan(binary, return: :index)
      |> Enum.map(fn [{start, len}, {id_s, id_l} | _] ->
        id = binary |> binary_part(id_s, id_l) |> String.to_integer()
        {id, start + len}
      end)
      |> Enum.reduce(%{}, fn {id, offset}, acc ->
        case parse_object_at(binary, offset) do
          {:ok, value} -> Map.put(acc, id, value)
          :error -> acc
        end
      end)

    # Objects packed into object streams (PDF 1.5+).
    Enum.reduce(direct, direct, fn
      {_id, {:stream, %{"Type" => {:name, "ObjStm"}} = dict, data}}, acc ->
        Map.merge(unpack_objstm(dict, data), acc)

      _, acc ->
        acc
    end)
  end

  defp parse_object_at(binary, offset) do
    rest = binary_part(binary, offset, byte_size(binary) - offset)
    {value, after_value} = parse_value(skip_ws(rest))

    case after_value |> skip_ws() do
      "stream" <> body ->
        body = String.replace_prefix(body, "\r\n", "") |> String.replace_prefix("\n", "")
        data = stream_bytes(body, value)
        {:ok, {:stream, value, decode(value, data)}}

      _ ->
        {:ok, value}
    end
  rescue
    _ -> :error
  end

  defp stream_bytes(body, dict) do
    case dict["Length"] do
      n when is_integer(n) and n <= byte_size(body) -> binary_part(body, 0, n)
      _ -> body |> :binary.split("endstream") |> hd() |> String.trim_trailing()
    end
  end

  defp decode(dict, data) do
    filters =
      case dict["Filter"] do
        {:name, f} -> [f]
        list when is_list(list) -> for {:name, f} <- list, do: f
        _ -> []
      end

    Enum.reduce(filters, data, fn
      "FlateDecode", d -> inflate(d)
      _other, d -> d
    end)
  end

  defp inflate(data) do
    z = :zlib.open()

    try do
      :zlib.inflateInit(z)
      z |> :zlib.inflate(data) |> IO.iodata_to_binary()
    rescue
      _ -> data
    after
      :zlib.close(z)
    end
  end

  defp unpack_objstm(dict, data) do
    n = dict["N"] || 0
    first = dict["First"] || 0
    header = binary_part(data, 0, min(first, byte_size(data)))
    nums = header |> String.split(~r/\s+/, trim: true) |> Enum.map(&String.to_integer/1)

    nums
    |> Enum.chunk_every(2)
    |> Enum.take(n)
    |> Map.new(fn [id, off] ->
      start = first + off
      {value, _} = parse_value(skip_ws(binary_part(data, start, byte_size(data) - start)))
      {id, value}
    end)
  rescue
    _ -> %{}
  end

  ## Values (shared by objects and content streams)

  @ws [?\s, ?\n, ?\r, ?\t, ?\f, 0]
  @delims ~c"()<>[]{}/%"

  defp skip_ws(<<c, rest::binary>>) when c in @ws, do: skip_ws(rest)
  defp skip_ws(<<?%, rest::binary>>), do: rest |> skip_comment() |> skip_ws()
  defp skip_ws(bin), do: bin

  defp skip_comment(<<c, rest::binary>>) when c in [?\n, ?\r], do: rest
  defp skip_comment(<<_, rest::binary>>), do: skip_comment(rest)
  defp skip_comment(<<>>), do: <<>>

  # Returns {value, rest}. References "n g R" become {:ref, n}.
  defp parse_value(<<"<<", rest::binary>>), do: parse_dict(skip_ws(rest), %{})
  defp parse_value(<<"[", rest::binary>>), do: parse_array(skip_ws(rest), [])
  defp parse_value(<<"(", rest::binary>>), do: parse_literal(rest, 0, [])
  defp parse_value(<<"<", rest::binary>>), do: parse_hex(rest, [])
  defp parse_value(<<"/", rest::binary>>), do: parse_name(rest, [])

  defp parse_value(bin) do
    {token, rest} = take_token(bin)

    case token do
      "true" -> {true, rest}
      "false" -> {false, rest}
      "null" -> {nil, rest}
      _ -> parse_number_or_ref(token, rest)
    end
  end

  defp parse_number_or_ref(token, rest) do
    case Integer.parse(token) do
      {n, ""} ->
        # "n g R" is a reference.
        case Regex.run(~r/\A\s*(\d+)\s+R(?![A-Za-z])/, rest) do
          [whole, _g] ->
            {{:ref, n}, binary_part(rest, byte_size(whole), byte_size(rest) - byte_size(whole))}

          nil ->
            {n, rest}
        end

      _ ->
        case Float.parse(normalize_number(token)) do
          {f, ""} -> {f, rest}
          _ -> {{:op, token}, rest}
        end
    end
  end

  defp normalize_number("." <> _ = t), do: "0" <> t
  defp normalize_number("-." <> t), do: "-0." <> t
  defp normalize_number(t), do: t

  defp take_token(bin), do: take_token(bin, [])
  defp take_token(<<c, _::binary>> = bin, acc) when c in @ws or c in @delims, do: {done(acc), bin}
  defp take_token(<<c, rest::binary>>, acc), do: take_token(rest, [c | acc])
  defp take_token(<<>>, acc), do: {done(acc), <<>>}

  defp done(acc), do: acc |> Enum.reverse() |> List.to_string()

  defp parse_dict(<<">>", rest::binary>>, acc), do: {acc, rest}

  defp parse_dict(<<"/", rest::binary>>, acc) do
    {{:name, key}, rest} = parse_name(rest, [])
    {value, rest} = parse_value(skip_ws(rest))
    parse_dict(skip_ws(rest), Map.put(acc, key, value))
  end

  defp parse_dict(<<>>, acc), do: {acc, <<>>}
  defp parse_dict(<<_, rest::binary>>, acc), do: parse_dict(skip_ws(rest), acc)

  defp parse_array(<<"]", rest::binary>>, acc), do: {Enum.reverse(acc), rest}
  defp parse_array(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  defp parse_array(bin, acc) do
    {value, rest} = parse_value(bin)
    parse_array(skip_ws(rest), [value | acc])
  end

  defp parse_name(<<c, _::binary>> = bin, acc) when c in @ws or c in @delims,
    do: {{:name, unescape_name(done(acc))}, bin}

  defp parse_name(<<c, rest::binary>>, acc), do: parse_name(rest, [c | acc])
  defp parse_name(<<>>, acc), do: {{:name, unescape_name(done(acc))}, <<>>}

  defp unescape_name(name),
    do:
      Regex.replace(~r/#([0-9A-Fa-f]{2})/, name, fn _, hex -> <<String.to_integer(hex, 16)>> end)

  defp parse_hex(<<">", rest::binary>>, acc) do
    hex = acc |> Enum.reverse() |> List.to_string()
    hex = if rem(byte_size(hex), 2) == 1, do: hex <> "0", else: hex
    {{:string, Base.decode16!(hex, case: :mixed)}, rest}
  end

  defp parse_hex(<<c, rest::binary>>, acc) when c in @ws, do: parse_hex(rest, acc)
  defp parse_hex(<<c, rest::binary>>, acc), do: parse_hex(rest, [c | acc])
  defp parse_hex(<<>>, acc), do: parse_hex(">", acc)

  defp parse_literal(<<")", rest::binary>>, 0, acc), do: {{:string, done_bytes(acc)}, rest}

  defp parse_literal(<<")", rest::binary>>, depth, acc),
    do: parse_literal(rest, depth - 1, [?) | acc])

  defp parse_literal(<<"(", rest::binary>>, depth, acc),
    do: parse_literal(rest, depth + 1, [?( | acc])

  defp parse_literal(<<"\\", c, rest::binary>>, depth, acc) do
    case c do
      ?n -> parse_literal(rest, depth, [?\n | acc])
      ?r -> parse_literal(rest, depth, [?\r | acc])
      ?t -> parse_literal(rest, depth, [?\t | acc])
      ?b -> parse_literal(rest, depth, [?\b | acc])
      ?f -> parse_literal(rest, depth, [?\f | acc])
      ?\n -> parse_literal(rest, depth, acc)
      ?\r -> parse_literal(String.replace_prefix(rest, "\n", ""), depth, acc)
      c when c in ?0..?7 -> octal(<<c, rest::binary>>, depth, acc)
      c -> parse_literal(rest, depth, [c | acc])
    end
  end

  defp parse_literal(<<c, rest::binary>>, depth, acc), do: parse_literal(rest, depth, [c | acc])
  defp parse_literal(<<>>, _depth, acc), do: {{:string, done_bytes(acc)}, <<>>}

  defp octal(bin, depth, acc) do
    [digits] = Regex.run(~r/\A[0-7]{1,3}/, bin)
    rest = binary_part(bin, byte_size(digits), byte_size(bin) - byte_size(digits))
    parse_literal(rest, depth, [String.to_integer(digits, 8) &&& 0xFF | acc])
  end

  defp done_bytes(acc), do: acc |> Enum.reverse() |> :erlang.list_to_binary()

  ## Page tree

  defp deref({:ref, id}, objects), do: deref(Map.get(objects, id), objects)
  defp deref({:stream, dict, _data}, _objects), do: dict
  defp deref(value, _objects), do: value

  defp pages(objects, binary) do
    root =
      case Regex.run(~r/\/Root\s+(\d+)\s+\d+\s+R/, binary, capture: :all_but_first) do
        [id] ->
          deref({:ref, String.to_integer(id)}, objects)

        _ ->
          Enum.find_value(objects, fn {_id, v} ->
            match?(%{"Type" => {:name, "Catalog"}}, v) && v
          end)
      end

    case root do
      %{"Pages" => pages} -> walk(deref(pages, objects), objects, %{}, 0)
      _ -> []
    end
  end

  # Kids in order; Resources and MediaBox are inherited.
  defp walk(node, objects, inherited, depth) when is_map(node) and depth < 64 do
    inherited =
      inherited
      |> maybe_put("Resources", node["Resources"])
      |> maybe_put("MediaBox", node["MediaBox"])

    case node do
      %{"Kids" => kids} ->
        Enum.flat_map(List.wrap(kids), &walk(deref(&1, objects), objects, inherited, depth + 1))

      %{"Type" => {:name, "Pages"}} ->
        []

      _ ->
        [Map.merge(inherited, Map.take(node, ["Contents", "Resources", "MediaBox"]))]
    end
  end

  defp walk(_node, _objects, _inherited, _depth), do: []

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stream_data({:ref, id}, objects) do
    case Map.get(objects, id) do
      {:stream, _dict, data} -> data
      other -> stream_data(other, objects)
    end
  end

  defp stream_data(list, objects) when is_list(list),
    do: list |> Enum.map(&stream_data(&1, objects)) |> Enum.join("\n")

  defp stream_data({:stream, _dict, data}, _objects), do: data
  defp stream_data(_other, _objects), do: ""

  ## Fonts

  # %{decode: fun(bytes) -> [{text, code}], width: fun(code) -> width/1000, two_byte: bool}
  defp font(ref, objects) do
    dict = deref(ref, objects) || %{}
    subtype = name_of(dict["Subtype"])
    two_byte = subtype == "Type0"
    to_unicode = dict["ToUnicode"] && parse_cmap(stream_data(dict["ToUnicode"], objects))

    widths =
      if two_byte do
        descendant =
          dict["DescendantFonts"]
          |> deref(objects)
          |> List.wrap()
          |> List.first()
          |> deref(objects)

        cid_widths(
          (descendant || %{})["W"] |> deref(objects),
          (descendant || %{})["DW"] || 1000,
          objects
        )
      else
        first = dict["FirstChar"] || 0

        list =
          dict["Widths"] |> deref(objects) |> List.wrap() |> Enum.map(&num(deref(&1, objects)))

        fn code -> Enum.at(list, code - first) || 600 end
      end

    encoding = simple_encoding(dict["Encoding"] |> deref(objects))

    %{
      two_byte: two_byte,
      width: widths,
      decode: fn code ->
        cond do
          to_unicode && Map.has_key?(to_unicode, code) -> to_unicode[code]
          two_byte -> nil
          true -> Map.get(encoding, code) || cp1252(code)
        end
      end
    }
  end

  defp name_of({:name, n}), do: n
  defp name_of(_), do: nil

  defp num(n) when is_number(n), do: n
  defp num(_), do: 0

  defp cid_widths(w, dw, objects) do
    table =
      (deref(w, objects) || [])
      |> Enum.map(&deref(&1, objects))
      |> cid_entries(%{})

    fn code -> Map.get(table, code, num(dw)) end
  end

  defp cid_entries([first, list | rest], acc) when is_integer(first) and is_list(list) do
    acc =
      list
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {w, i}, a -> Map.put(a, first + i, num(w)) end)

    cid_entries(rest, acc)
  end

  defp cid_entries([a, b, w | rest], acc) when is_integer(a) and is_integer(b) do
    acc = Enum.reduce(a..b//1, acc, &Map.put(&2, &1, num(w)))
    cid_entries(rest, acc)
  end

  defp cid_entries(_rest, acc), do: acc

  # ToUnicode: bfchar and bfrange (both forms) into %{code => string}.
  defp parse_cmap(data) do
    chars =
      ~r/beginbfchar(.*?)endbfchar/s
      |> Regex.scan(data, capture: :all_but_first)
      |> Enum.flat_map(fn [body] ->
        ~r/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]*)>/
        |> Regex.scan(body, capture: :all_but_first)
        |> Enum.map(fn [src, dst] -> {String.to_integer(src, 16), utf16(dst)} end)
      end)

    ranges =
      ~r/beginbfrange(.*?)endbfrange/s
      |> Regex.scan(data, capture: :all_but_first)
      |> Enum.flat_map(fn [body] ->
        ~r/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(<[0-9A-Fa-f]*>|\[[^\]]*\])/
        |> Regex.scan(body, capture: :all_but_first)
        |> Enum.flat_map(fn [lo, hi, dst] ->
          lo = String.to_integer(lo, 16)
          hi = String.to_integer(hi, 16)

          if String.starts_with?(dst, "[") do
            ~r/<([0-9A-Fa-f]*)>/
            |> Regex.scan(dst, capture: :all_but_first)
            |> Enum.with_index()
            |> Enum.map(fn {[d], i} -> {lo + i, utf16(d)} end)
          else
            start = dst |> String.trim_leading("<") |> String.trim_trailing(">")
            base = String.to_integer(start, 16)
            width = byte_size(start)

            for code <- lo..min(hi, lo + 65_535)//1 do
              {code,
               utf16(Integer.to_string(base + code - lo, 16) |> String.pad_leading(width, "0"))}
            end
          end
        end)
      end)

    Map.new(chars ++ ranges)
  end

  defp utf16(""), do: ""

  defp utf16(hex) do
    bytes = Base.decode16!(hex, case: :mixed)

    case :unicode.characters_to_binary(bytes, {:utf16, :big}) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  # /Differences glyph names for simple fonts.
  defp simple_encoding(%{"Differences" => diffs}) when is_list(diffs) do
    {map, _} =
      Enum.reduce(diffs, {%{}, 0}, fn
        n, {map, _code} when is_integer(n) -> {map, n}
        {:name, glyph}, {map, code} -> {Map.put(map, code, glyph_char(glyph)), code + 1}
        _, acc -> acc
      end)

    map |> Enum.reject(fn {_c, v} -> is_nil(v) end) |> Map.new()
  end

  defp simple_encoding(_), do: %{}

  @glyphs %{
    "space" => " ",
    "quotesingle" => "'",
    "quoteright" => "’",
    "quoteleft" => "‘",
    "quotedbl" => "\"",
    "quotedblleft" => "“",
    "quotedblright" => "”",
    "hyphen" => "-",
    "endash" => "–",
    "emdash" => "—",
    "period" => ".",
    "comma" => ",",
    "colon" => ":",
    "semicolon" => ";",
    "exclam" => "!",
    "question" => "?",
    "parenleft" => "(",
    "parenright" => ")",
    "ellipsis" => "…",
    "ampersand" => "&",
    "slash" => "/",
    "zero" => "0",
    "one" => "1",
    "two" => "2",
    "three" => "3",
    "four" => "4",
    "five" => "5",
    "six" => "6",
    "seven" => "7",
    "eight" => "8",
    "nine" => "9"
  }

  defp glyph_char(<<c>>) when c in ?A..?Z or c in ?a..?z, do: <<c>>

  defp glyph_char("uni" <> hex) when byte_size(hex) == 4 do
    <<String.to_integer(hex, 16)::utf8>>
  rescue
    _ -> nil
  end

  defp glyph_char(name), do: Map.get(@glyphs, name)

  # WinAnsi is close to Windows-1252; printable ASCII and Latin-1 as is.
  @cp1252 %{
    0x91 => "‘",
    0x92 => "’",
    0x93 => "“",
    0x94 => "”",
    0x96 => "–",
    0x97 => "—",
    0x85 => "…",
    0x80 => "€"
  }

  defp cp1252(code) when code in 32..126, do: <<code>>
  defp cp1252(code) when code in 160..255, do: <<code::utf8>>
  defp cp1252(code), do: Map.get(@cp1252, code)

  ## Content streams

  @identity {1.0, 0.0, 0.0, 1.0, 0.0, 0.0}

  defp page_runs(page, objects) do
    resources = deref(page["Resources"], objects) || %{}
    content = stream_data(page["Contents"], objects)

    state = %{
      ctm: @identity,
      stack: [],
      tm: @identity,
      tlm: @identity,
      font: nil,
      size: 12.0,
      tc: 0.0,
      tw: 0.0,
      th: 1.0,
      tl: 0.0,
      runs: []
    }

    {state, _cache} = run(content, resources, objects, state, %{}, 0)
    Enum.reverse(state.runs)
  end

  defp run(content, resources, objects, state, cache, depth) when depth < 8 do
    tokens = tokenize(content)
    interpret(tokens, [], resources, objects, state, cache, depth)
  end

  defp run(_content, _resources, _objects, state, cache, _depth), do: {state, cache}

  defp tokenize(content), do: tokenize(skip_ws(content), [])
  defp tokenize(<<>>, acc), do: Enum.reverse(acc)

  defp tokenize(bin, acc) do
    case bin do
      # Inline images carry raw bytes; skip to their end.
      <<"BI", c, _::binary>> when c in @ws ->
        case :binary.split(bin, "EI") do
          [_, rest] -> tokenize(skip_ws(rest), acc)
          _ -> Enum.reverse(acc)
        end

      _ ->
        {value, rest} = parse_value(bin)
        tokenize(skip_ws(rest), [value | acc])
    end
  end

  defp interpret([], _operands, _res, _objects, state, cache, _depth), do: {state, cache}

  defp interpret([{:op, op} | rest], operands, res, objects, state, cache, depth) do
    {state, cache} = apply_op(op, Enum.reverse(operands), res, objects, state, cache, depth)
    interpret(rest, [], res, objects, state, cache, depth)
  end

  defp interpret([value | rest], operands, res, objects, state, cache, depth),
    do: interpret(rest, [value | operands], res, objects, state, cache, depth)

  defp apply_op("q", _, _res, _o, s, c, _d), do: {%{s | stack: [s.ctm | s.stack]}, c}

  defp apply_op("Q", _, _res, _o, %{stack: [ctm | rest]} = s, c, _d),
    do: {%{s | ctm: ctm, stack: rest}, c}

  defp apply_op("Q", _, _res, _o, s, c, _d), do: {s, c}

  defp apply_op("cm", [a, b, cc, d, e, f], _res, _o, s, c, _d),
    do: {%{s | ctm: mul({num(a), num(b), num(cc), num(d), num(e), num(f)}, s.ctm)}, c}

  defp apply_op("BT", _, _res, _o, s, c, _d), do: {%{s | tm: @identity, tlm: @identity}, c}

  defp apply_op("Tf", [{:name, name}, size], res, objects, s, cache, _d) do
    {font, cache} =
      case cache do
        %{^name => f} ->
          {f, cache}

        _ ->
          fonts = deref(res["Font"], objects) || %{}
          f = font(fonts[name], objects)
          {f, Map.put(cache, name, f)}
      end

    {%{s | font: font, size: num(size) * 1.0}, cache}
  end

  defp apply_op("Tc", [v], _res, _o, s, c, _d), do: {%{s | tc: num(v)}, c}
  defp apply_op("Tw", [v], _res, _o, s, c, _d), do: {%{s | tw: num(v)}, c}
  defp apply_op("Tz", [v], _res, _o, s, c, _d), do: {%{s | th: num(v) / 100}, c}
  defp apply_op("TL", [v], _res, _o, s, c, _d), do: {%{s | tl: num(v)}, c}

  defp apply_op("Tm", [a, b, cc, d, e, f], _res, _o, s, c, _d) do
    m = {num(a), num(b), num(cc), num(d), num(e), num(f)}
    {%{s | tm: m, tlm: m}, c}
  end

  defp apply_op("Td", [tx, ty], _res, _o, s, c, _d), do: {next_line(s, num(tx), num(ty)), c}

  defp apply_op("TD", [tx, ty], _res, _o, s, c, _d),
    do: {next_line(%{s | tl: -num(ty)}, num(tx), num(ty)), c}

  defp apply_op("T*", _, _res, _o, s, c, _d), do: {next_line(s, 0, -s.tl), c}
  defp apply_op("Tj", [{:string, _} = str], _res, _o, s, c, _d), do: {show(s, [str]), c}
  defp apply_op("TJ", [list], _res, _o, s, c, _d) when is_list(list), do: {show(s, list), c}

  defp apply_op("'", [{:string, _} = str], _res, _o, s, c, _d),
    do: {s |> next_line(0, -s.tl) |> show([str]), c}

  defp apply_op("\"", [aw, ac, {:string, _} = str], _res, _o, s, c, _d),
    do: {%{s | tw: num(aw), tc: num(ac)} |> next_line(0, -s.tl) |> show([str]), c}

  defp apply_op("Do", [{:name, name}], res, objects, s, cache, depth) do
    xobjects = deref(res["XObject"], objects) || %{}

    case xobjects[name] do
      {:ref, id} ->
        case Map.get(objects, id) do
          {:stream, %{"Subtype" => {:name, "Form"}} = dict, data} ->
            matrix =
              case dict["Matrix"] do
                [a, b, cc, d, e, f] -> {num(a), num(b), num(cc), num(d), num(e), num(f)}
                _ -> @identity
              end

            inner = %{s | ctm: mul(matrix, s.ctm), stack: []}
            form_res = deref(dict["Resources"], objects) || res
            {done, _} = run(data, form_res, objects, inner, %{}, depth + 1)
            {%{s | runs: done.runs}, cache}

          _ ->
            {s, cache}
        end

      _ ->
        {s, cache}
    end
  end

  defp apply_op(_op, _operands, _res, _o, s, c, _d), do: {s, c}

  defp next_line(s, tx, ty) do
    m = mul({1.0, 0.0, 0.0, 1.0, tx, ty}, s.tlm)
    %{s | tm: m, tlm: m}
  end

  # Shows strings (and TJ adjustments), recording one run per call.
  defp show(%{font: nil} = s, _items), do: s

  defp show(s, items) do
    start = position(s)

    {s, text} =
      Enum.reduce(items, {s, []}, fn
        {:string, str}, {s, acc} ->
          Enum.reduce(codes(str, s.font), {s, acc}, fn code, {s, acc} ->
            char = s.font.decode.(code) || ""
            w = s.font.width.(code) / 1000
            space = if char == " ", do: s.tw, else: 0.0
            tx = (w * s.size + s.tc + space) * s.th
            {%{s | tm: mul({1.0, 0.0, 0.0, 1.0, tx, 0.0}, s.tm)}, [char | acc]}
          end)

        n, {s, acc} when is_number(n) ->
          tx = -n / 1000 * s.size * s.th
          # A wide gap inside TJ is a word space the PDF did not draw.
          acc = if n < -200, do: [" " | acc], else: acc
          {%{s | tm: mul({1.0, 0.0, 0.0, 1.0, tx, 0.0}, s.tm)}, acc}

        _, acc ->
          acc
      end)

    text = text |> Enum.reverse() |> Enum.join()
    {end_x, _} = position(s)
    {x, y} = start
    size = abs(scale_y(s)) * s.size

    if String.trim(text) == "" do
      s
    else
      %{s | runs: [%{x: x, y: y, end_x: end_x, size: size, text: text} | s.runs]}
    end
  end

  defp codes(str, %{two_byte: true}), do: for(<<c::16 <- str>>, do: c)
  defp codes(str, _font), do: :binary.bin_to_list(str)

  defp position(s) do
    {_, _, _, _, x, y} = mul(s.tm, s.ctm)
    {x, y}
  end

  defp scale_y(s) do
    {_a, _b, _c, d, _e, _f} = mul(s.tm, s.ctm)
    d
  end

  # Row-vector affine matrices, as PDF composes them.
  defp mul({a1, b1, c1, d1, e1, f1}, {a2, b2, c2, d2, e2, f2}) do
    {a1 * a2 + b1 * c2, a1 * b2 + b1 * d2, c1 * a2 + d1 * c2, c1 * b2 + d1 * d2,
     e1 * a2 + f1 * c2 + e2, e1 * b2 + f1 * d2 + f2}
  end
end
