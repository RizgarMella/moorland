defmodule MoorlandWeb.BreakdownComponents do
  @moduledoc """
  Shared pieces of the script breakdown UI, used by the editor's Breakdown
  panel and the full breakdown page. Category colours come from the
  `.bd-cat-*` rules in app.css, which also colour tags in the preview.
  """
  use MoorlandWeb, :html

  alias Moorland.Scripts
  alias Moorland.Scripts.{Breakdown, BreakdownTag}

  attr :category, :string, required: true
  attr :class, :any, default: nil

  def category_dot(assigns) do
    ~H"""
    <span class={["bd-dot inline-block size-2 shrink-0 rounded-full", "bd-cat-#{@category}", @class]}></span>
    """
  end

  attr :category, :string, required: true

  def category_label(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5">
      <.category_dot category={@category} />
      <span>{BreakdownTag.category_label(@category)}</span>
    </span>
    """
  end

  @doc "Eighths of a page as a script supervisor writes them: `1 3/8`, `5/8`, `2`."
  def eighths(n) when is_integer(n) and n > 0 do
    case {div(n, 8), rem(n, 8)} do
      {0, r} -> "#{r}/8"
      {w, 0} -> "#{w}"
      {w, r} -> "#{w} #{r}/8"
    end
  end

  def eighths(0), do: "0"
  def eighths(_n), do: "—"

  def int_ext_label(:int), do: "INT"
  def int_ext_label(:ext), do: "EXT"
  def int_ext_label(:int_ext), do: "INT/EXT"
  def int_ext_label(_), do: "—"

  @doc """
  The editor's Breakdown panel: tag the words just highlighted in the
  preview, and see what is already tagged in the scene the cursor is in.
  """
  attr :script, :map, required: true
  attr :role, :atom, required: true
  attr :user_id, :integer, required: true
  attr :draft, :any, required: true, doc: "%{line, text} of words picked to tag, or nil"
  attr :scene, :any, required: true, doc: "the cursor's scene sheet from Breakdown.build/2"
  attr :unplaced, :integer, required: true

  def breakdown_panel(assigns) do
    ~H"""
    <div id="breakdown-panel" class="flex flex-1 flex-col">
      <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold">Breakdown</h2>
        <div class="flex items-center gap-3">
          <.link
            id="open-shots"
            navigate={~p"/scripts/#{@script.id}/shots"}
            class="flex items-center gap-1 text-xs text-base-content/60 transition hover:text-base-content"
          >
            Shots
          </.link>
          <.link
            id="open-schedule"
            navigate={~p"/scripts/#{@script.id}/schedule"}
            class="flex items-center gap-1 text-xs text-base-content/60 transition hover:text-base-content"
          >
            Stripboard
          </.link>
          <.link
            id="open-breakdown"
            navigate={~p"/scripts/#{@script.id}/breakdown"}
            class="flex items-center gap-1 text-xs text-base-content/60 transition hover:text-base-content"
          >
            All scenes <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
          </.link>
        </div>
      </div>

      <form
        :if={@draft && Scripts.can_comment?(@role)}
        id="tag-form"
        phx-submit="create_tag"
        class="space-y-3 border-b border-base-300 px-4 py-3"
      >
        <div class="text-xs text-base-content/60">
          Tagging
          <span class="font-medium text-base-content">“{String.slice(@draft.text, 0, 60)}”</span>
          on line {@draft.line + 1}
        </div>
        <fieldset class="flex flex-wrap gap-1" aria-label="Category">
          <label :for={{key, label} <- BreakdownTag.categories()} class={"bd-cat-#{key}"}>
            <input
              type="radio"
              name="category"
              value={key}
              checked={key == "props"}
              class="peer sr-only"
            />
            <span class="bd-pick inline-flex cursor-pointer items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] peer-focus-visible:ring-2 peer-focus-visible:ring-base-content/30">
              {label}
            </span>
          </label>
        </fieldset>
        <div class="flex gap-2">
          <input
            id="tag-name"
            type="text"
            name="name"
            value={@draft.text}
            required
            maxlength="120"
            autocomplete="off"
            phx-mounted={JS.focus()}
            class="input input-bordered input-sm min-w-0 flex-1"
            aria-label="Element name"
          />
          <button type="submit" class="btn btn-neutral btn-sm">Tag</button>
        </div>
        <button
          type="button"
          phx-click="cancel_tag"
          class="text-xs text-base-content/50 hover:text-base-content"
        >
          Cancel
        </button>
      </form>

      <p
        :if={!@draft && Scripts.can_comment?(@role)}
        class="border-b border-base-300 px-4 py-3 text-xs text-base-content/50"
      >
        Highlight words in the preview and choose <b>Tag</b> to add a prop, costume, vehicle or
        anything else a department needs.
      </p>

      <div class="px-4 py-3">
        <div :if={!@scene} class="text-xs text-base-content/40">
          Put the cursor in a scene to see its breakdown.
        </div>

        <div :if={@scene} id="breakdown-scene">
          <div class="flex items-baseline gap-2">
            <span class="text-xs font-semibold tabular-nums text-base-content/50">
              {scene_label(@scene)}
            </span>
            <span class="min-w-0 flex-1 truncate font-mono text-xs font-semibold">
              {@scene.heading}
            </span>
            <span class="text-[11px] tabular-nums text-base-content/50">
              {eighths(@scene.eighths)} pg
            </span>
          </div>

          <p :if={@scene.elements == %{}} class="mt-3 text-xs text-base-content/40">
            Nothing tagged in this scene yet.
          </p>

          <div
            :for={{category, entries} <- ordered_elements(@scene.elements)}
            class={["mt-3", "bd-cat-#{category}"]}
          >
            <div class="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wider text-base-content/60">
              <.category_dot category={category} />
              {BreakdownTag.category_label(category)}
            </div>
            <ul class="mt-1 flex flex-wrap gap-1">
              <li
                :for={entry <- entries}
                class="bd-chip group inline-flex items-center gap-1 rounded-md border px-1.5 py-0.5 text-xs transition"
              >
                <span>{entry.name}</span>
                <span :if={entry.auto} class="text-[10px] text-base-content/40">speaks</span>
                <button
                  :if={removable_ids(entry, @role, @user_id) != ""}
                  type="button"
                  phx-click="remove_tags"
                  phx-value-ids={removable_ids(entry, @role, @user_id)}
                  class="rounded p-0.5 text-base-content/30 opacity-0 transition group-hover:opacity-100 hover:text-error focus:opacity-100"
                  title={"Untag #{entry.name} in this scene"}
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </li>
            </ul>
          </div>
        </div>

        <.link
          :if={@unplaced > 0}
          navigate={~p"/scripts/#{@script.id}/breakdown"}
          class="mt-4 flex items-center gap-1.5 text-xs text-warning"
        >
          <.icon name="hero-exclamation-triangle" class="size-3.5" />
          {@unplaced} {if @unplaced == 1, do: "tag has", else: "tags have"} lost their words
        </.link>
      </div>
    </div>
    """
  end

  @doc """
  A scene's number for display. A scene added to a locked script has none
  until the numbers are extended, and shows a dash.
  """
  def scene_label(%{label: label}) when is_binary(label), do: label
  def scene_label(_scene), do: "—"

  @doc "Scene elements as `[{category, entries}]` in breakdown-sheet order."
  def ordered_elements(elements) do
    for {category, _label} <- BreakdownTag.categories(),
        entries = Map.get(elements, category),
        entries != nil,
        do: {category, entries}
  end

  @doc "Comma-separated ids of an entry's tags the viewer may remove."
  def removable_ids(entry, role, user_id) do
    entry.tags
    |> Enum.filter(&(&1.author_id == user_id or Scripts.can_edit?(role)))
    |> Enum.map_join(",", & &1.id)
  end

  @doc "The sheet of the scene containing `line`, from a `Breakdown.build/2` result."
  def scene_for_line(%{scenes: scenes}, line) when is_integer(line),
    do: Breakdown.scene_at(scenes, line)

  def scene_for_line(%{scenes: [first | _]}, _line), do: first
  def scene_for_line(_breakdown, _line), do: nil
end
