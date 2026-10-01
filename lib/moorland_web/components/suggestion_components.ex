defmodule MoorlandWeb.SuggestionComponents do
  @moduledoc """
  Suggested edits in the History panel: what a peer (often an AI assistant)
  proposes, the lines it would change, and Apply or Dismiss for editors.
  """
  use MoorlandWeb, :html

  alias Moorland.Scripts

  attr :suggestions, :list, required: true
  attr :open_id, :any, required: true
  attr :content, :string, required: true
  attr :role, :atom, required: true

  def suggestions_section(assigns) do
    ~H"""
    <section :if={@suggestions != []} id="suggestions" class="border-b border-base-300 px-4 py-3">
      <h3 class="text-xs font-semibold">
        Suggested edits <span class="font-normal text-base-content/50">{length(@suggestions)}</span>
      </h3>
      <ul class="mt-2 space-y-2">
        <li
          :for={s <- @suggestions}
          id={"suggestion-#{s.id}"}
          class="rounded-md border border-base-300 p-2"
        >
          <div class="flex items-center gap-1.5 text-[11px] text-base-content/60">
            <span class="font-semibold text-base-content">{s.remote_author || "someone"}</span>
            <span
              :if={s.from_assistant}
              class="rounded bg-primary/15 px-1 text-[9px] font-semibold uppercase text-primary"
              title="Suggested by an AI assistant connected as a peer"
            >
              AI
            </span>
            <span class="ml-auto">{Calendar.strftime(s.inserted_at, "%-d %b %H:%M")}</span>
          </div>
          <p :if={s.message != ""} class="mt-1 text-xs">{s.message}</p>

          <div class="mt-1.5 flex items-center gap-1.5">
            <button
              type="button"
              phx-click="toggle_suggestion"
              phx-value-id={s.id}
              class="text-[11px] text-base-content/60 hover:text-base-content"
            >
              {if @open_id == s.id, do: "Hide changes", else: "Show changes"}
            </button>
            <span class="flex-1"></span>
            <button
              :if={Scripts.can_edit?(@role)}
              type="button"
              phx-click="dismiss_suggestion"
              phx-value-id={s.id}
              class="btn btn-ghost btn-xs"
            >
              Dismiss
            </button>
            <button
              :if={Scripts.can_edit?(@role)}
              type="button"
              phx-click="apply_suggestion"
              phx-value-id={s.id}
              class="btn btn-neutral btn-xs"
              title="Merge these changes into the script; anything written since is kept"
            >
              Apply
            </button>
          </div>

          <div
            :if={@open_id == s.id}
            class="mt-2 max-h-64 overflow-y-auto rounded bg-base-200/60 p-1.5 font-mono text-[11px] leading-snug"
          >
            <% changes = changes(@content, s.content) %>
            <div :for={{op, line} <- changes} class={line_class(op)}>
              {if op == :ins, do: "+ ", else: "− "}{line}
            </div>
            <p :if={changes == []} class="text-base-content/50">No changes against the text now.</p>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  # Only what changes, at most 80 lines of it.
  defp changes(current, proposed) do
    current
    |> Scripts.diff_lines(proposed)
    |> Enum.reject(fn {op, _} -> op == :eq end)
    |> Enum.take(80)
  end

  defp line_class(:ins), do: "whitespace-pre-wrap text-success"
  defp line_class(:del), do: "whitespace-pre-wrap text-error line-through"
end
