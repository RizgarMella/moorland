defmodule Moorland.Scripts.Pipeline do
  @moduledoc """
  The story-to-script pipeline: a work grows from an idea to a short story to
  a full story to a script, each stage its own document. Pure functions: the
  stages, and `adapt/1`, which turns a story into the start of a script.
  """

  @stages [
    {"idea", "Idea", "prose"},
    {"short_story", "Short story", "prose"},
    {"story", "Story", "prose"},
    {"script", "Script", "screenplay"}
  ]

  def stages, do: Enum.map(@stages, fn {key, label, _kind} -> {key, label} end)
  def stage_keys, do: Enum.map(@stages, &elem(&1, 0))

  def label(stage) do
    case List.keyfind(@stages, stage, 0) do
      {_, label, _} -> label
      nil -> nil
    end
  end

  @doc "The kind of document a stage is written as."
  def kind_for(stage) do
    case List.keyfind(@stages, stage, 0) do
      {_, _, kind} -> kind
      nil -> nil
    end
  end

  @doc "The stage after `stage`, or nil at the end of the line."
  def next(stage) do
    keys = stage_keys()

    case Enum.find_index(keys, &(&1 == stage)) do
      nil -> nil
      i -> Enum.at(keys, i + 1)
    end
  end

  def index(stage), do: Enum.find_index(stage_keys(), &(&1 == stage))

  @doc """
  The first draft of a script from a story. Chapters (`#`) become Fountain
  sections; scenes (`##`), scene breaks and chapters without scenes become
  scene stubs (forced headings to rename), each with a synopsis from its
  first sentence and its prose kept in the boneyard below it, so the writer
  adapts with the story in view and nothing of it prints.
  """
  def adapt(prose) do
    {chapters, _} =
      prose
      |> Moorland.Scripts.FrontMatter.body()
      |> String.replace(~r/\/\*[\s\S]*?\*\//, "")
      |> String.split("\n")
      |> Enum.reduce({[], nil}, &collect/2)

    body =
      chapters
      |> Enum.reverse()
      |> Enum.map(&render_chapter/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    "/* Adapted from the story. Each scene stub below keeps its prose in a boneyard\n" <>
      "   like this one: rename the stub, then write the scene. */\n\n" <> body <> "\n"
  end

  # Chapters are %{title, scenes}; scenes are %{title, lines}.
  defp collect(line, {chapters, _}) do
    trimmed = String.trim(line)

    cond do
      Regex.match?(~r/^#\s+\S/, trimmed) ->
        title = String.replace(trimmed, ~r/^#\s+/, "")
        {[%{title: title, scenes: []} | chapters], nil}

      Regex.match?(~r/^##+\s+\S/, trimmed) ->
        title = String.replace(trimmed, ~r/^##+\s+/, "")
        {add_scene(chapters, title), nil}

      Regex.match?(~r/^\s*([*\-_]\s*){3,}$/, trimmed) ->
        {add_scene(chapters, nil), nil}

      true ->
        {add_line(chapters, line), nil}
    end
  end

  defp add_scene([], title), do: [%{title: nil, scenes: [%{title: title, lines: []}]}]

  defp add_scene([chapter | rest], title),
    do: [%{chapter | scenes: chapter.scenes ++ [%{title: title, lines: []}]} | rest]

  # A blank line never opens a scene; only text does.
  defp add_line(chapters, line) do
    blank? = String.trim(line) == ""

    case chapters do
      [] when blank? ->
        []

      [] ->
        add_line(add_scene([], nil), line)

      [%{scenes: []} | _] when blank? ->
        chapters

      [%{scenes: []} = chapter | rest] ->
        add_line(add_scene([chapter | rest], chapter.title), line)

      _ ->
        append_line(chapters, line)
    end
  end

  defp append_line([chapter | rest], line) do
    {scenes, [last]} = Enum.split(chapter.scenes, -1)
    [%{chapter | scenes: scenes ++ [%{last | lines: last.lines ++ [line]}]} | rest]
  end

  defp render_chapter(%{title: title, scenes: scenes}) do
    section = if title, do: ["# " <> title], else: []

    stubs =
      scenes
      |> Enum.map(&render_scene/1)
      |> Enum.reject(&is_nil/1)

    Enum.join(section ++ stubs, "\n\n")
  end

  defp render_scene(%{title: title, lines: lines}) do
    prose = lines |> Enum.join("\n") |> String.trim()

    if prose == "" and is_nil(title) do
      nil
    else
      heading = "." <> String.upcase(title || "New scene")

      synopsis =
        case first_sentence(prose) do
          nil -> []
          sentence -> ["= " <> sentence]
        end

      kept =
        if prose == "", do: [], else: ["/*\n" <> String.replace(prose, "*/", "* /") <> "\n*/"]

      Enum.join([heading | synopsis ++ kept], "\n\n")
    end
  end

  defp first_sentence(""), do: nil

  defp first_sentence(prose) do
    prose
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/[*_]+/, "")
    |> then(&(Regex.run(~r/^.*?[.!?…](?=\s|$)/u, &1) || [&1]))
    |> hd()
    |> String.trim()
    |> String.slice(0, 160)
  end
end
