defmodule MoorlandWeb.ProductionComponents do
  @moduledoc """
  The header every pre-production page shares: a way back to the script,
  tabs across the production documents (in the order they depend on each
  other) and the page's own title and actions.
  """
  use MoorlandWeb, :html

  @tabs [
    {:breakdown, "Breakdown", "hero-tag"},
    {:shots, "Shots", "hero-video-camera"},
    {:schedule, "Stripboard", "hero-calendar-days"},
    {:production, "Production", "hero-clipboard-document-check"},
    {:media, "Media", "hero-photo"}
  ]

  attr :script, :map, required: true
  attr :current, :atom, required: true, values: Enum.map(@tabs, &elem(&1, 0))
  attr :title, :string, required: true
  slot :subtitle
  slot :actions, doc: "page buttons beside the title, such as Print"

  def production_header(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <div class="print:hidden">
      <.link
        id="back-to-script"
        navigate={~p"/scripts/#{@script.id}"}
        class="group inline-flex max-w-full items-center gap-1 text-sm text-base-content/60 transition-colors hover:text-base-content"
        title="Back to the script"
      >
        <.icon
          name="hero-arrow-left"
          class="size-3.5 shrink-0 transition-transform group-hover:-translate-x-0.5"
        />
        <span class="truncate">{@script.title}</span>
      </.link>

      <nav
        id="production-tabs"
        aria-label="Production documents"
        class="-mx-4 mt-3 flex gap-1 overflow-x-auto border-b border-base-300 px-4 [scrollbar-width:none] sm:mx-0 sm:px-0"
      >
        <.link
          :for={{key, label, icon} <- @tabs}
          id={"open-#{key}"}
          navigate={tab_path(@script, key)}
          aria-current={key == @current && "page"}
          title={label}
          class={[
            "-mb-px flex shrink-0 items-center gap-1.5 border-b-2 px-2.5 pb-2 pt-1 text-sm transition-colors",
            if(key == @current,
              do: "border-base-content font-medium text-base-content",
              else:
                "border-transparent text-base-content/55 hover:border-base-300 hover:text-base-content"
            )
          ]}
        >
          <.icon name={icon} class="size-4" />
          <span class={key != @current && "hidden sm:inline"}>{label}</span>
        </.link>
      </nav>

      <div class="mt-6 flex flex-wrap items-end gap-x-4 gap-y-2">
        <div class="min-w-0 flex-1">
          <h1 class="text-2xl font-semibold tracking-tight">{@title}</h1>
          <p :if={@subtitle != []} class="mt-0.5 truncate text-sm text-base-content/60">
            {render_slot(@subtitle)}
          </p>
        </div>
        <div :if={@actions != []} class="flex items-center gap-1">
          {render_slot(@actions)}
        </div>
      </div>
    </div>
    """
  end

  defp tab_path(script, :breakdown), do: ~p"/scripts/#{script.id}/breakdown"
  defp tab_path(script, :shots), do: ~p"/scripts/#{script.id}/shots"
  defp tab_path(script, :schedule), do: ~p"/scripts/#{script.id}/schedule"
  defp tab_path(script, :production), do: ~p"/scripts/#{script.id}/production"
  defp tab_path(script, :media), do: ~p"/scripts/#{script.id}/media"
end
