defmodule Moorland.Scripts.Merge do
  @moduledoc """
  Line-based three-way merge for concurrent script edits.

  Given the common ancestor (`base`), the version already on the server
  (`ours`) and the incoming save (`theirs`):

    * edits to different regions are both kept;
    * insertions by both sides at the same spot are both kept (ours first),
      so two writers appending to the script never lose each other's work;
    * when both sides rewrote the same base lines differently, the incoming
      save wins for that region only (the rest of the document still merges).
  """

  def three_way(base, ours, theirs) do
    cond do
      ours == theirs -> ours
      base == ours -> theirs
      base == theirs -> ours
      true -> do_merge(base, ours, theirs)
    end
  end

  defp do_merge(base, ours, theirs) do
    base_lines = String.split(base, "\n")
    our_hunks = hunks(base_lines, String.split(ours, "\n"))
    their_hunks = hunks(base_lines, String.split(theirs, "\n"))

    walk(base_lines, our_hunks, their_hunks, 0, [])
    |> Enum.join("\n")
  end

  # A hunk {bstart, bend, lines} replaces base[bstart, bend) with `lines`.
  defp hunks(base_lines, side_lines) do
    List.myers_difference(base_lines, side_lines)
    |> collect(0, [])
    |> coalesce()
  end

  defp collect([], _pos, acc), do: Enum.reverse(acc)
  defp collect([{:eq, lines} | rest], pos, acc), do: collect(rest, pos + length(lines), acc)

  defp collect([{:del, lines} | rest], pos, acc) do
    n = length(lines)
    collect(rest, pos + n, [{pos, pos + n, []} | acc])
  end

  defp collect([{:ins, lines} | rest], pos, acc), do: collect(rest, pos, [{pos, pos, lines} | acc])

  # Adjacent delete+insert pairs form a single replace hunk.
  defp coalesce(hunks) do
    Enum.reduce(hunks, [], fn
      {s2, e2, l2}, [{s1, e1, l1} | rest] when e1 == s2 -> [{s1, e2, l1 ++ l2} | rest]
      hunk, acc -> [hunk | acc]
    end)
    |> Enum.reverse()
  end

  defp walk(base, [], [], pos, acc), do: acc ++ slice(base, pos, length(base))

  defp walk(base, ours, theirs, pos, acc) do
    case {ours, theirs} do
      {[o | o_rest], [t | t_rest]} ->
        cond do
          o == t ->
            {s, e, lines} = o
            walk(base, o_rest, t_rest, e, acc ++ slice(base, pos, s) ++ lines)

          both_insert_same_spot?(o, t) ->
            {s, _, o_lines} = o
            {_, _, t_lines} = t
            walk(base, o_rest, t_rest, s, acc ++ slice(base, pos, s) ++ o_lines ++ t_lines)

          overlap?(o, t) ->
            {region_s, region_e, o_rest2, t_rest2, t_in} = conflict_region(ours, theirs)
            resolved = apply_hunks(base, region_s, region_e, t_in)
            walk(base, o_rest2, t_rest2, region_e, acc ++ slice(base, pos, region_s) ++ resolved)

          start_of(o) <= start_of(t) ->
            {s, e, lines} = o
            walk(base, o_rest, theirs, e, acc ++ slice(base, pos, s) ++ lines)

          true ->
            {s, e, lines} = t
            walk(base, ours, t_rest, e, acc ++ slice(base, pos, s) ++ lines)
        end

      {[{s, e, lines} | o_rest], []} ->
        walk(base, o_rest, [], e, acc ++ slice(base, pos, s) ++ lines)

      {[], [{s, e, lines} | t_rest]} ->
        walk(base, [], t_rest, e, acc ++ slice(base, pos, s) ++ lines)
    end
  end

  defp start_of({s, _, _}), do: s

  defp both_insert_same_spot?({s1, e1, _}, {s2, e2, _}), do: s1 == e1 and s2 == e2 and s1 == s2

  defp overlap?({s1, e1, _}, {s2, e2, _}), do: s1 < e2 and s2 < e1

  # Expands the conflict to cover every hunk (on either side) that touches it,
  # returning the untouched remainders and the incoming side's hunks within.
  defp conflict_region([o | o_rest], [t | t_rest]) do
    {s1, e1, _} = o
    {s2, e2, _} = t
    grow(min(s1, s2), max(e1, e2), o_rest, t_rest, [t])
  end

  defp grow(region_s, region_e, ours, theirs, t_in) do
    cond do
      match?([_ | _], ours) and overlap?(hd(ours), {region_s, region_e, []}) ->
        [{s, e, _} | rest] = ours
        grow(min(region_s, s), max(region_e, e), rest, theirs, t_in)

      match?([_ | _], theirs) and overlap?(hd(theirs), {region_s, region_e, []}) ->
        [{s, e, _} = h | rest] = theirs
        grow(min(region_s, s), max(region_e, e), ours, rest, t_in ++ [h])

      true ->
        {region_s, region_e, ours, theirs, t_in}
    end
  end

  # Applies one side's hunks to base[region_s, region_e).
  defp apply_hunks(base, region_s, region_e, hunks) do
    {out, pos} =
      Enum.reduce(hunks, {[], region_s}, fn {s, e, lines}, {out, pos} ->
        s = max(s, region_s)
        e = min(e, region_e)
        {out ++ slice(base, pos, s) ++ lines, e}
      end)

    out ++ slice(base, pos, region_e)
  end

  defp slice(_base, from, to) when from >= to, do: []
  defp slice(base, from, to), do: Enum.slice(base, from, to - from)
end
