defmodule MoorlandWeb.CharacterComponents do
  @moduledoc """
  The Characters tab of the Notes panel: everyone in the work, found in its
  text (speaking parts in a script, names in prose), each with an optional
  character sheet. Sheets are notes of kind "character" whose first line is
  the name, so they sync to peers like any note.
  """
  use MoorlandWeb, :html

  alias Moorland.Scripts
  alias Moorland.Scripts.{Names, Script, Stats}

  @fields ~w(Role Age Wants Needs Arc Notes)

  # Proper nouns autocomplete should offer but that are never characters.
  @calendar ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday January February
               March April May June July August September October November December)

  @doc "A new sheet for `name`."
  def sheet_template(name) do
    Enum.join([String.trim(name) | Enum.map(@fields, &"#{&1}: ")], "\n")
  end

  @doc "The name a sheet is for: its first line."
  def sheet_name(%{body: body}), do: body |> String.split("\n") |> hd() |> String.trim()

  @doc """
  `[%{name, count, sheet}]`: names in the text, most present first (lines
  spoken in a script, mentions in prose), then sheets for names the text
  does not have yet.
  """
  def rows(%Script{} = script, notes) do
    sheets = Enum.filter(notes, &(&1.kind == "character"))

    found =
      if Script.prose?(script) do
        script.content |> Names.harvest() |> Enum.reject(&(&1.name in @calendar))
      else
        script
        |> Stats.compute_for(script.content)
        |> Map.fetch!(:characters)
        |> Enum.map(&%{name: &1.name, count: &1.lines})
      end

    key = fn name -> String.downcase(name) end
    by_name = Map.new(sheets, &{key.(sheet_name(&1)), &1})

    in_text = Enum.map(found, &Map.put(&1, :sheet, Map.get(by_name, key.(&1.name))))
    named = MapSet.new(found, &key.(&1.name))

    extra =
      for sheet <- sheets,
          not MapSet.member?(named, key.(sheet_name(sheet))),
          do: %{name: sheet_name(sheet), count: 0, sheet: sheet}

    in_text ++ extra
  end

  attr :rows, :list, required: true
  attr :editing, :any, required: true
  attr :role, :atom, required: true
  attr :current_user_id, :integer, required: true
  attr :prose, :boolean, required: true

  def characters_tab(assigns) do
    ~H"""
    <div id="characters-tab">
      <p class="border-b border-base-300 px-4 py-2 text-[11px] text-base-content/50">
        {if @prose,
          do: "Everyone named in the story, most mentioned first.",
          else: "Everyone with lines, most lines first."} Give anyone a sheet to keep who they are straight.
      </p>

      <form
        :if={Scripts.can_comment?(@role)}
        id="add-character-form"
        phx-submit="add_sheet"
        class="flex gap-1.5 border-b border-base-300 px-4 py-2"
      >
        <input
          type="text"
          name="name"
          required
          maxlength="80"
          autocomplete="off"
          placeholder="A character not written in yet"
          class="input input-bordered input-xs min-w-0 flex-1"
        />
        <button type="submit" class="btn btn-ghost btn-xs">Add</button>
      </form>

      <ul class="divide-y divide-base-200">
        <li :for={row <- @rows} id={"character-#{slug(row.name)}"} class="px-4 py-2">
          <div class="flex items-center gap-2">
            <span class="min-w-0 flex-1 truncate text-sm font-medium">{row.name}</span>
            <span :if={row.count > 0} class="text-[11px] tabular-nums text-base-content/40">
              {row.count}
            </span>
            <span :if={row.count == 0} class="text-[11px] text-base-content/40">not in yet</span>
            <button
              :if={!row.sheet && Scripts.can_comment?(@role)}
              type="button"
              phx-click="add_sheet"
              phx-value-name={row.name}
              class="rounded px-1.5 text-[11px] text-base-content/60 hover:bg-base-200 hover:text-base-content"
            >
              + Sheet
            </button>
            <button
              :if={row.sheet && @editing != row.sheet.id}
              type="button"
              phx-click="edit_sheet"
              phx-value-id={row.sheet.id}
              class="rounded px-1.5 text-[11px] text-base-content/60 hover:bg-base-200 hover:text-base-content"
            >
              Sheet
            </button>
          </div>

          <form
            :if={row.sheet && @editing == row.sheet.id}
            id={"sheet-form-#{row.sheet.id}"}
            phx-submit="save_sheet"
            class="mt-2 space-y-1.5"
          >
            <input type="hidden" name="note_id" value={row.sheet.id} />
            <textarea
              name="body"
              rows="8"
              readonly={!editable?(row.sheet, @role, @current_user_id)}
              class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed"
            >{row.sheet.body}</textarea>
            <div class="flex items-center gap-1.5">
              <button
                :if={editable?(row.sheet, @role, @current_user_id)}
                type="submit"
                class="btn btn-neutral btn-xs"
              >
                Save
              </button>
              <button
                type="button"
                phx-click="edit_sheet"
                phx-value-id=""
                class="btn btn-ghost btn-xs"
              >
                Close
              </button>
              <span :if={row.sheet.remote_author} class="text-[11px] text-base-content/40">
                by {row.sheet.remote_author} (via peer)
              </span>
            </div>
          </form>
        </li>
        <li :if={@rows == []} class="px-4 py-6 text-center text-sm text-base-content/40">
          No one yet. Names appear here as you write them.
        </li>
      </ul>
    </div>
    """
  end

  defp editable?(sheet, role, user_id), do: sheet.author_id == user_id or role == :owner

  defp slug(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, "-")
end
