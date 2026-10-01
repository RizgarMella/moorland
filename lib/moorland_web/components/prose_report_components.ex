defmodule MoorlandWeb.ProseReportComponents do
  @moduledoc """
  The prose half of the editor's Reports panel: chapter lengths and style
  checks from `Scripts.ProseReport`. Findings are pointers, not rules; each
  links to its line.
  """
  use MoorlandWeb, :html

  attr :report, :map, required: true

  def prose_report(assigns) do
    ~H"""
    <div id="prose-report" class="space-y-5 border-t border-base-300 p-4">
      <section :if={@report.chapters != []} id="prose-chapters">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
          Chapters
        </h3>
        <% longest = @report.chapters |> Enum.map(& &1.words) |> Enum.max() |> max(1) %>
        <ul class="mt-2 space-y-1.5">
          <li :for={chapter <- @report.chapters}>
            <.jump
              line={chapter.line}
              class="flex w-full items-baseline justify-between gap-2 text-left text-xs"
            >
              <span class="min-w-0 truncate">{chapter.title}</span>
              <span class="shrink-0 tabular-nums text-base-content/50">
                {chapter.words} w · {chapter.minutes} min
              </span>
            </.jump>
            <div class="mt-0.5 h-1 rounded-full bg-base-200">
              <div
                class="h-1 rounded-full bg-neutral/60"
                style={"width: #{chapter.words / longest * 100}%"}
              >
              </div>
            </div>
          </li>
        </ul>
      </section>

      <section id="prose-style">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">Style</h3>
        <p class="mt-1 text-[11px] text-base-content/50">
          Pointers, not rules: each is worth a look, not always a change.
        </p>

        <.finding
          title="Echoes"
          count={length(@report.echoes)}
          hint="the same word three times in a paragraph"
        >
          <li :for={echo <- Enum.take(@report.echoes, 8)}>
            <.jump line={echo.line} class="text-xs">“{echo.word}” ×{echo.count}</.jump>
          </li>
        </.finding>

        <.finding title="Adverbs" count={@report.adverbs.count} hint="-ly words">
          <li :for={adverb <- @report.adverbs.top}>
            <.jump line={adverb.line} class="text-xs">{adverb.word} ×{adverb.count}</.jump>
          </li>
        </.finding>

        <.finding
          title="Possible passive voice"
          count={@report.passive.count}
          hint="“was taken”, “were seen”"
        >
          <li :for={example <- @report.passive.examples}>
            <.jump line={example.line} class="text-xs">{example.phrase}</.jump>
          </li>
        </.finding>

        <div class="mt-3 text-xs">
          <div class="flex items-baseline justify-between">
            <span class="font-medium">Dialogue tags</span>
            <span class="text-[11px] text-base-content/50">said/asked {@report.tags.plain}</span>
          </div>
          <p :if={@report.tags.showy != []} class="mt-0.5 text-[11px] text-base-content/60">
            Showier: {Enum.map_join(@report.tags.showy, ", ", fn {word, n} -> "#{word} ×#{n}" end)}
          </p>
        </div>
      </section>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :hint, :string, required: true
  slot :inner_block, required: true

  defp finding(assigns) do
    ~H"""
    <details class="group mt-3 text-xs">
      <summary class="flex cursor-pointer list-none items-baseline justify-between">
        <span class="font-medium">
          <.icon name="hero-chevron-right" class="size-3 transition group-open:rotate-90" />
          {@title}
        </span>
        <span class={["tabular-nums", (@count > 0 && "text-base-content") || "text-base-content/40"]}>
          {@count}
        </span>
      </summary>
      <p class="ml-4 text-[11px] text-base-content/50">{@hint}</p>
      <ul :if={@count > 0} class="ml-4 mt-1 space-y-0.5">{render_slot(@inner_block)}</ul>
    </details>
    """
  end

  attr :line, :integer, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  defp jump(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="jump_to_line"
      phx-value-line={@line}
      class={["rounded hover:underline", @class]}
      title={"Go to line #{@line + 1}"}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end
end
