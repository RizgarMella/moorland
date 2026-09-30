defmodule MoorlandWeb.RevisionComponents do
  @moduledoc """
  Revision mode in the editor: the toolbar chip naming the revision being
  shown, and the History panel section that starts sets and steps between
  them. The marks themselves are drawn in the preview by revisions.js.
  """
  use MoorlandWeb, :html

  alias Moorland.Scripts
  alias Moorland.Scripts.RevisionSet

  @doc "The label printed on revised pages: `Blue Rev. 12/10/26`."
  def revision_label(%RevisionSet{color: color, inserted_at: at}),
    do: "#{color} Rev. #{Calendar.strftime(at, "%d/%m/%y")}"

  attr :set, :any, required: true

  def revision_chip(assigns) do
    ~H"""
    <span
      :if={@set}
      id="revision-chip"
      class={[
        "shrink-0 whitespace-nowrap rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-black/70",
        "rev-swatch-#{RevisionSet.color_key(@set.color)}"
      ]}
      title={"#{@set.color} revision: changed lines are starred in the preview"}
    >
      {@set.color}
    </span>
    """
  end

  attr :sets, :list, required: true
  attr :shown, :any, required: true
  attr :role, :atom, required: true

  def revision_section(assigns) do
    assigns = assign(assigns, :next, RevisionSet.color_name(length(assigns.sets)))

    ~H"""
    <section id="revision-section" class="border-b border-base-300 px-4 py-3">
      <div class="flex items-center justify-between gap-2">
        <h3 class="text-xs font-semibold">Revisions</h3>
        <button
          :if={@sets != [] && Scripts.can_edit?(@role)}
          id="clear-revisions"
          type="button"
          phx-click="clear_revisions"
          data-confirm="End revision mode? Revision colours and marks are cleared; the text is not changed."
          class="text-[11px] text-base-content/50 hover:text-error"
        >
          End
        </button>
      </div>

      <p :if={@sets == []} class="mt-1 text-[11px] text-base-content/50">
        Once the draft is locked, each round of changes is a coloured revision. Changed lines are starred in the margin.
      </p>

      <div
        :if={@sets != []}
        class="mt-2 flex flex-wrap gap-1"
        role="group"
        aria-label="Show changes in"
      >
        <button
          :for={set <- @sets}
          type="button"
          phx-click="show_revision"
          phx-value-id={set.id}
          class={[
            "rounded-full px-2 py-0.5 text-[11px] font-medium text-black/70 ring-offset-1 ring-offset-base-100 transition",
            "rev-swatch-#{RevisionSet.color_key(set.color)}",
            @shown && @shown.id == set.id && "ring-2 ring-base-content/60",
            (!@shown || @shown.id != set.id) && "opacity-70 hover:opacity-100"
          ]}
          title={"Show changes since #{set.color} began, #{Calendar.strftime(set.inserted_at, "%-d %b %Y")}"}
        >
          {set.color}
        </button>
      </div>

      <button
        :if={Scripts.can_edit?(@role)}
        id="start-revision"
        type="button"
        phx-click="start_revision"
        class={[
          "mt-2 flex w-full items-center justify-center gap-1.5 rounded-md border border-base-300 px-2 py-1 text-xs transition hover:bg-base-200"
        ]}
      >
        <span class={["size-2.5 rounded-full", "rev-swatch-#{RevisionSet.color_key(@next)}"]}></span>
        Start {@next} revision
      </button>
    </section>
    """
  end
end
