defmodule MoorlandWeb.ScriptLive.Editor do
  use MoorlandWeb, :live_view

  alias Moorland.Scripts
  alias Moorland.Scripts.Stats
  alias MoorlandWeb.Presence

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    {script, role} = Scripts.get_script!(scope, id)

    if connected?(socket) do
      Scripts.subscribe(script.id)

      {:ok, _} =
        Presence.track(self(), Scripts.topic(script.id), scope.user.id, %{
          email: scope.user.email,
          joined_at: System.system_time(:second)
        })
    end

    socket =
      socket
      |> assign(
        script: script,
        role: role,
        page_title: script.title,
        panel: nil,
        anchor: nil,
        show_resolved: false,
        nav_open: false,
        diff: nil,
        stats: nil,
        char_meta: %{},
        title_form: nil,
        sprint: nil,
        lookup_q: "",
        lookup_result: nil,
        presences: presence_list(script.id)
      )
      |> load_panel_data()

    {:ok, socket, layout: false}
  end

  defp load_panel_data(socket) do
    script = socket.assigns.script

    assign(socket,
      comments: Scripts.list_comments(script),
      notes: Scripts.list_notes(script),
      versions: Scripts.list_versions(script),
      collaborators: Scripts.list_collaborators(script),
      peers: Moorland.Peers.list_peers(socket.assigns.current_scope),
      peer_shares: Scripts.list_peer_shares(script),
      bin: Scripts.list_bin(script),
      shelf: Scripts.list_shelf(socket.assigns.current_scope)
    )
  end

  defp presence_list(script_id) do
    Scripts.topic(script_id)
    |> Presence.list()
    |> Enum.map(fn {_id, %{metas: [meta | _]}} -> meta.email end)
    |> Enum.sort()
  end

  ## Events from the editor hook

  @impl true
  def handle_event("autosave", %{"content" => content} = params, socket) do
    %{current_scope: scope, script: script, role: role} = socket.assigns
    base_version = params["base_version"]

    if Scripts.can_edit?(role) do
      case Scripts.save_content(scope, script, content, base_version) do
        {:ok, saved} ->
          ack = %{at: DateTime.to_unix(saved.updated_at), version: saved.content_version}
          # A merge means the server text differs from what the client sent.
          ack = if saved.content != content, do: Map.put(ack, :content, saved.content), else: ack

          {:noreply,
           socket
           |> assign(:script, saved)
           |> push_event("save_ack", ack)}

        {:error, _} ->
          {:noreply, push_event(socket, "save_error", %{})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("cursor_line", %{"line" => line, "text" => text}, socket) do
    {:noreply, assign(socket, :anchor, %{line: line, text: String.trim(text)})}
  end

  def handle_event("comment_on_selection", %{"line" => line, "text" => text}, socket) do
    {:noreply,
     socket
     |> assign(:anchor, %{line: line, text: String.trim(text)})
     |> assign(:panel, "comments")}
  end

  ## Chrome

  def handle_event("rename", %{"title" => title}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    title = String.trim(title)

    if title != "" and title != script.title do
      case Scripts.update_script(scope, script, %{title: title}) do
        {:ok, saved} -> {:noreply, assign(socket, script: saved, page_title: saved.title)}
        {:error, _} -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_panel", %{"panel" => panel}, socket) do
    new_panel = if(socket.assigns.panel == panel, do: nil, else: panel)
    socket = assign(socket, panel: new_panel, diff: nil)

    if new_panel == "comments" do
      Scripts.mark_notifications_read(socket.assigns.current_scope, socket.assigns.script)
    end

    socket =
      if new_panel == "reports",
        do:
          assign(socket,
            stats: Stats.compute(socket.assigns.script.content),
            char_meta: Scripts.list_character_meta(socket.assigns.script)
          ),
        else: socket

    {:noreply, socket}
  end

  def handle_event("set_goals", params, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    attrs = %{
      goal_words: parse_goal(params["goal_words"]),
      goal_pages: parse_goal(params["goal_pages"])
    }

    case Scripts.update_script(scope, script, attrs) do
      {:ok, saved} -> {:noreply, assign(socket, :script, saved)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("set_gender", %{"name" => name, "gender" => gender}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.set_character_gender(scope, script, name, gender)
    {:noreply, assign(socket, :char_meta, Scripts.list_character_meta(script))}
  end

  defp parse_goal(value) do
    case Integer.parse(to_string(value || "")) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  ## Bin & Shelf

  def handle_event("bin_cut", _params, socket) do
    {:noreply, push_event(socket, "cut_selection", %{})}
  end

  def handle_event("bin_add", %{"body" => body}, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    case Scripts.create_bin_snippet(scope, script, body) do
      {:ok, _} -> {:noreply, load_panel_data(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("shelf_add", %{"body" => body}, socket) do
    case Scripts.create_shelf_snippet(socket.assigns.current_scope, body) do
      {:ok, _} -> {:noreply, load_panel_data(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("snippet_insert", %{"id" => id}, socket) do
    snippet =
      Enum.find(socket.assigns.bin ++ socket.assigns.shelf, &(&1.id == String.to_integer(id)))

    if snippet do
      {:noreply, push_event(socket, "insert_at_cursor", %{text: snippet.body})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("snippet_shelf", %{"id" => id}, socket) do
    Scripts.move_snippet_to_shelf(socket.assigns.current_scope, String.to_integer(id))
    {:noreply, load_panel_data(socket)}
  end

  def handle_event("snippet_delete", %{"id" => id}, socket) do
    Scripts.delete_snippet(socket.assigns.current_scope, String.to_integer(id))
    {:noreply, load_panel_data(socket)}
  end

  ## Lookup

  def handle_event("lookup", %{"q" => q}, socket) do
    {:noreply, assign(socket, lookup_q: q, lookup_result: Moorland.Lookup.fetch(q))}
  end

  ## Writing sprints

  def handle_event("sprint_start", %{"mins" => mins}, socket) do
    mins = String.to_integer(mins)
    Process.send_after(self(), :sprint_tick, 1_000)

    {:noreply,
     assign(socket, :sprint, %{
       ends_at: System.system_time(:second) + mins * 60,
       start_words: Stats.compute(socket.assigns.script.content).words,
       mins: mins,
       remaining: mins * 60
     })}
  end

  def handle_event("sprint_stop", _params, socket) do
    {:noreply, assign(socket, :sprint, nil)}
  end

  ## Title page form

  def handle_event("open_title_form", params, socket) do
    fields =
      Map.new(
        ~w(title credit author source draft_date contact copyright),
        &{&1, String.trim(to_string(params[&1] || ""))}
      )

    fields =
      if fields["draft_date"] == "" do
        %{fields | "draft_date" => Calendar.strftime(Date.utc_today(), "%B %d, %Y")}
      else
        fields
      end

    {:noreply, assign(socket, :title_form, fields)}
  end

  def handle_event("close_title_form", _params, socket) do
    {:noreply, assign(socket, :title_form, nil)}
  end

  def handle_event("apply_title_page", params, socket) do
    block = build_title_block(params)

    {:noreply,
     socket
     |> assign(:title_form, nil)
     |> push_event("set_title_page", %{block: block})}
  end

  defp build_title_block(params) do
    field = fn key -> params[key] |> to_string() |> String.trim() end

    single = fn key, label ->
      case field.(key) do
        "" -> []
        value -> ["#{label}: #{value}"]
      end
    end

    contact =
      case field.("contact") do
        "" ->
          []

        value ->
          ["Contact:" | value |> String.split(~r/\r?\n/, trim: true) |> Enum.map(&("    " <> String.trim(&1)))]
      end

    lines =
      single.("title", "Title") ++
        single.("credit", "Credit") ++
        single.("author", "Author") ++
        single.("source", "Source") ++
        single.("draft_date", "Draft date") ++
        contact ++
        single.("copyright", "Copyright")

    case lines do
      [] -> ""
      _ -> Enum.join(lines, "\n") <> "\n\n"
    end
  end

  def handle_event("toggle_nav", _params, socket) do
    open = !socket.assigns.nav_open

    {:noreply,
     socket
     |> assign(:nav_open, open)
     |> push_event("scene_nav", %{open: open})}
  end

  def handle_event("export", %{"format" => format} = params, socket)
      when format in ["pdf", "fountain", "fdx", "html", "markdown", "sides"] do
    {:noreply,
     push_event(socket, "export", %{format: format, watermark: params["watermark"] || ""})}
  end

  ## Comments

  def handle_event("add_comment", %{"body" => body} = params, socket) do
    %{current_scope: scope, script: script, anchor: anchor} = socket.assigns

    attrs =
      if params["anchored"] == "true" && anchor,
        do: %{body: body, line_no: anchor.line, anchor_text: anchor.text},
        else: %{body: body}

    case Scripts.create_comment(scope, script, attrs) do
      {:ok, _} -> {:noreply, load_panel_data(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not add the comment.")}
    end
  end

  def handle_event("reply_comment", %{"parent_id" => parent_id, "body" => body}, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    case Scripts.create_comment(scope, script, %{body: body, parent_id: parent_id}) do
      {:ok, _} -> {:noreply, load_panel_data(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not add the reply.")}
    end
  end

  def handle_event("resolve_comment", %{"id" => id, "resolved" => resolved}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.resolve_comment(scope, script, id, resolved == "true")
    {:noreply, load_panel_data(socket)}
  end

  def handle_event("delete_comment", %{"id" => id}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.delete_comment(scope, script, id)
    {:noreply, load_panel_data(socket)}
  end

  def handle_event("toggle_resolved", _params, socket) do
    {:noreply, assign(socket, :show_resolved, !socket.assigns.show_resolved)}
  end

  def handle_event("jump_to_line", %{"line" => line}, socket) do
    {:noreply, push_event(socket, "jump_to_line", %{line: line})}
  end

  ## Notes

  def handle_event("add_note", %{"body" => body, "color" => color}, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    case Scripts.create_note(scope, script, %{body: body, color: color}) do
      {:ok, _} -> {:noreply, load_panel_data(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not add the note.")}
    end
  end

  def handle_event("toggle_pin", %{"id" => id, "pinned" => pinned}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.update_note(scope, script, id, %{pinned: pinned == "true"})
    {:noreply, load_panel_data(socket)}
  end

  def handle_event("delete_note", %{"id" => id}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.delete_note(scope, script, id)
    {:noreply, load_panel_data(socket)}
  end

  ## Versions

  def handle_event("snapshot", %{"message" => message}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    message = if String.trim(message) == "", do: nil, else: String.trim(message)

    case Scripts.create_snapshot(scope, script, message) do
      {:ok, _} -> {:noreply, load_panel_data(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not create the snapshot.")}
    end
  end

  def handle_event("show_diff", %{"version-id" => id}, socket) do
    script = socket.assigns.script
    version = Scripts.get_version!(script, id)
    diff = Scripts.diff_lines(version.content, script.content)
    {:noreply, assign(socket, :diff, %{version: version, lines: diff})}
  end

  def handle_event("close_diff", _params, socket) do
    {:noreply, assign(socket, :diff, nil)}
  end

  def handle_event("restore", %{"version-id" => id}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    version = Scripts.get_version!(script, id)

    case Scripts.restore_version(scope, script, version) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> assign(script: saved, diff: nil)
         |> load_panel_data()
         |> push_event("remote_content", %{
           content: saved.content,
           version: saved.content_version
         })}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not restore this version.")}
    end
  end

  ## Sharing

  def handle_event("add_collaborator", %{"email" => email, "role" => role}, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    case Scripts.add_collaborator(scope, script, email, role) do
      {:ok, _} ->
        {:noreply, load_panel_data(socket)}

      {:error, :user_not_found} ->
        {:noreply,
         put_flash(socket, :error, "No account found for #{email}. Ask them to register first.")}

      {:error, :is_owner} ->
        {:noreply, put_flash(socket, :error, "That is the owner of this script.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not add that collaborator.")}
    end
  end

  def handle_event("update_role", %{"collab_id" => id, "role" => role}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.update_collaborator_role(scope, script, id, role)
    {:noreply, load_panel_data(socket)}
  end

  def handle_event("remove_collaborator", %{"id" => id}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.remove_collaborator(scope, script, id)
    {:noreply, load_panel_data(socket)}
  end

  def handle_event("set_peer_share", %{"peer_id" => peer_id, "role" => role}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.set_peer_share(scope, script, String.to_integer(peer_id), role)
    {:noreply, load_panel_data(socket)}
  end

  ## PubSub & timers

  @impl true
  def handle_info(:sprint_tick, socket) do
    case socket.assigns.sprint do
      nil ->
        {:noreply, socket}

      sprint ->
        remaining = sprint.ends_at - System.system_time(:second)
        words = Stats.compute(socket.assigns.script.content).words - sprint.start_words

        if remaining <= 0 do
          {:noreply,
           socket
           |> assign(:sprint, nil)
           |> put_flash(:info, "Sprint done — #{max(words, 0)} words in #{sprint.mins} minutes.")}
        else
          Process.send_after(self(), :sprint_tick, 1_000)
          {:noreply, assign(socket, :sprint, %{sprint | remaining: remaining})}
        end
    end
  end

  def handle_info({:content_saved, _script_id, user_id, content, version}, socket) do
    socket = update(socket, :script, &%{&1 | content: content, content_version: version})

    socket =
      if socket.assigns.panel == "reports",
        do: assign(socket, :stats, Stats.compute(content)),
        else: socket

    if user_id != socket.assigns.current_scope.user.id do
      {:noreply, push_event(socket, "remote_content", %{content: content, version: version})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:script_updated, _id}, socket) do
    {script, role} = Scripts.get_script!(socket.assigns.current_scope, socket.assigns.script.id)
    {:noreply, assign(socket, script: script, role: role, page_title: script.title)}
  end

  def handle_info({event, _id}, socket)
      when event in [:comments_changed, :notes_changed, :versions_changed, :collaborators_changed] do
    {:noreply, load_panel_data(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :presences, presence_list(socket.assigns.script.id))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Render helpers

  defp initials(email), do: email |> String.first() |> String.upcase()

  # Comments, notes and versions may have arrived from a peer installation:
  # no local user, just a handle. Local authors show as their email.
  defp author_label(%{remote_author: name}) when is_binary(name) and name != "", do: name
  defp author_label(%{author: %{email: email}}) when is_binary(email), do: email
  defp author_label(_record), do: "someone"

  defp role_label(:owner), do: "Owner"
  defp role_label(role), do: role |> to_string() |> String.capitalize()

  defp time_ago(dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> Calendar.strftime(dt, "%b %d, %Y")
    end
  end

  defp visible_comments(comments, true), do: comments
  defp visible_comments(comments, false), do: Enum.reject(comments, & &1.resolved_at)

  defp note_color_class("yellow"),
    do: "bg-amber-50 border-amber-200 dark:bg-amber-950/40 dark:border-amber-900"

  defp note_color_class("blue"),
    do: "bg-sky-50 border-sky-200 dark:bg-sky-950/40 dark:border-sky-900"

  defp note_color_class("green"),
    do: "bg-emerald-50 border-emerald-200 dark:bg-emerald-950/40 dark:border-emerald-900"

  defp note_color_class("pink"),
    do: "bg-rose-50 border-rose-200 dark:bg-rose-950/40 dark:border-rose-900"

  defp note_color_class(_),
    do: "bg-zinc-50 border-zinc-200 dark:bg-zinc-800/40 dark:border-zinc-700"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen flex-col bg-base-100 print:hidden">
      <Layouts.flash_group flash={@flash} />

      <button
        id="header-reveal"
        type="button"
        onclick="moorlandUI.toggleHeader()"
        class="header-reveal"
        title="Show the toolbar"
      >
        <.icon name="hero-chevron-down" class="size-3.5" />
      </button>

      <header class="editor-header flex h-12 shrink-0 items-center gap-3 border-b border-base-300 bg-base-100 px-3">
        <.link navigate={~p"/scripts"} class="rounded p-1.5 text-base-content/60 hover:bg-base-200">
          <.icon name="hero-chevron-left" class="size-4" />
        </.link>

        <button
          type="button"
          onclick="moorlandUI.toggleMobilePane()"
          class="rounded p-1.5 text-base-content/60 hover:bg-base-200 md:hidden"
          title="Switch between editor and preview"
        >
          <.icon name="hero-arrows-right-left" class="size-4" />
        </button>

        <button
          phx-click="toggle_nav"
          class={[
            "rounded p-1.5 hover:bg-base-200",
            (@nav_open && "text-base-content") || "text-base-content/60"
          ]}
          title="Scene navigator"
        >
          <.icon name="hero-queue-list" class="size-4" />
        </button>

        <form
          :if={Scripts.can_edit?(@role)}
          id="rename-form"
          phx-change="rename"
          phx-submit="rename"
          class="min-w-0"
        >
          <input
            type="text"
            name="title"
            value={@script.title}
            phx-debounce="800"
            autocomplete="off"
            class="w-56 truncate rounded border-0 bg-transparent px-1 py-0.5 text-sm font-medium focus:bg-base-200 focus:outline-none"
          />
        </form>
        <div :if={!Scripts.can_edit?(@role)} class="truncate text-sm font-medium">
          {@script.title}
        </div>

        <span class="rounded-full bg-base-200 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-base-content/60">
          {role_label(@role)}
        </span>

        <span
          id="save-status"
          class="text-xs text-base-content/40"
          data-saved-text="Saved"
          data-saving-text="Saving…"
          data-offline-text="Offline — changes kept locally"
        >
        </span>

        <div class="ml-auto flex items-center gap-3">
          <div class="dropdown dropdown-end">
            <div
              tabindex="0"
              role="button"
              class="flex cursor-pointer items-center gap-1.5 rounded-md px-2.5 py-1 text-xs font-medium text-base-content/60 hover:text-base-content"
              title="Export"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" />
              <span class="hidden lg:inline">Export</span>
            </div>
            <ul
              tabindex="0"
              class="dropdown-content menu z-50 mt-1 w-52 rounded-lg border border-base-300 bg-base-100 p-1 text-xs shadow-lg"
            >
              <li><button phx-click="export" phx-value-format="pdf">PDF — clean</button></li>
              <li>
                <button phx-click="export" phx-value-format="pdf" phx-value-watermark="DRAFT">
                  PDF — “DRAFT” watermark
                </button>
              </li>
              <li>
                <button phx-click="export" phx-value-format="pdf" phx-value-watermark="FINAL">
                  PDF — “FINAL” watermark
                </button>
              </li>
              <li><button phx-click="export" phx-value-format="fountain">Fountain (.fountain)</button></li>
              <li><button phx-click="export" phx-value-format="fdx">Final Draft (.fdx)</button></li>
              <li><button phx-click="export" phx-value-format="html">Web page (.html)</button></li>
              <li><button phx-click="export" phx-value-format="markdown">Markdown (.md)</button></li>
              <li><button phx-click="export" phx-value-format="sides">Script sides (PDF)…</button></li>
            </ul>
          </div>

          <div class="dropdown dropdown-end">
            <div
              tabindex="0"
              role="button"
              class="flex cursor-pointer items-center rounded-md px-2 py-1 text-xs font-medium text-base-content/60 hover:text-base-content"
              title="Paper & font"
            >
              Aa
            </div>
            <div
              tabindex="0"
              class="dropdown-content z-50 mt-1 w-44 rounded-lg border border-base-300 bg-base-100 p-2 text-xs shadow-lg"
            >
              <div class="px-1 text-[10px] font-semibold uppercase tracking-wider text-base-content/40">
                Paper
              </div>
              <div class="mt-1 flex gap-1">
                <button
                  :for={{name, label} <- [{"default", "Classic"}, {"sepia", "Sepia"}, {"slate", "Slate"}]}
                  type="button"
                  data-paper={name}
                  onclick={"moorlandUI.setPaper('#{name}')"}
                  class="flex-1 rounded border border-base-300 px-1 py-1 hover:bg-base-200"
                >
                  {label}
                </button>
              </div>
              <div class="mt-2 px-1 text-[10px] font-semibold uppercase tracking-wider text-base-content/40">
                Focus
              </div>
              <div class="mt-1">
                <button
                  type="button"
                  data-typewriter
                  onclick="moorlandUI.toggleTypewriter()"
                  class="w-full rounded border border-base-300 px-1 py-1 hover:bg-base-200"
                  title="Keep the line you're writing vertically centered"
                >
                  Typewriter scrolling
                </button>
              </div>

              <div class="mt-2 px-1 text-[10px] font-semibold uppercase tracking-wider text-base-content/40">
                Font
              </div>
              <div class="mt-1 flex gap-1">
                <button
                  :for={{name, label} <- [{"default", "Courier"}, {"mono", "Modern"}, {"serif", "Book"}]}
                  type="button"
                  data-font={name}
                  onclick={"moorlandUI.setFont('#{name}')"}
                  class="flex-1 rounded border border-base-300 px-1 py-1 hover:bg-base-200"
                >
                  {label}
                </button>
              </div>
            </div>
          </div>

          <Layouts.theme_toggle />

          <button
            id="pin-header"
            type="button"
            onclick="moorlandUI.togglePin()"
            class="rounded p-1.5 text-base-content/40 hover:bg-base-200"
            title="Pin the toolbar (unpinned, it slides away while you write)"
          >
            <.icon name="hero-map-pin" class="size-4" />
          </button>

          <button
            id="fullscreen-toggle"
            type="button"
            onclick="moorlandUI.toggleFullscreen()"
            class="rounded p-1.5 text-base-content/40 hover:bg-base-200"
            title="Browser full screen (Esc leaves it)"
          >
            <.icon name="hero-arrows-pointing-out" class="fs-enter size-4" />
            <.icon name="hero-arrows-pointing-in" class="fs-exit size-4" />
          </button>

          <button
            id="hide-header"
            type="button"
            onclick="moorlandUI.toggleHeader()"
            class="rounded p-1.5 text-base-content/40 hover:bg-base-200"
            title="Hide the toolbar — the small chevron at the top of the page brings it back"
          >
            <.icon name="hero-chevron-up" class="size-4" />
          </button>

          <div class="flex -space-x-1.5" title={Enum.join(@presences, ", ")}>
            <span
              :for={email <- Enum.take(@presences, 5)}
              class="flex size-6 items-center justify-center rounded-full border-2 border-base-100 bg-neutral text-[10px] font-semibold text-neutral-content"
              title={email}
            >
              {initials(email)}
            </span>
          </div>

          <div class="flex items-center gap-0.5 rounded-lg bg-base-200 p-0.5">
            <button
              :for={
                {panel, icon, label} <- [
                  {"comments", "hero-chat-bubble-left", "Comments"},
                  {"notes", "hero-clipboard-document-list", "Notes"},
                  {"bin", "hero-archive-box", "Bin"},
                  {"lookup", "hero-book-open", "Lookup"},
                  {"history", "hero-clock", "History"},
                  {"reports", "hero-chart-bar", "Reports"},
                  {"share", "hero-user-plus", "Share"}
                ]
              }
              phx-click="toggle_panel"
              phx-value-panel={panel}
              class={[
                "flex items-center gap-1.5 rounded-md px-2.5 py-1 text-xs font-medium transition",
                @panel == panel && "bg-base-100 shadow-sm",
                @panel != panel && "text-base-content/60 hover:text-base-content"
              ]}
              title={label}
            >
              <.icon name={icon} class="size-4" />
              <span class="hidden lg:inline">{label}</span>
              <span
                :if={panel == "comments" && visible_comments(@comments, false) != []}
                class="rounded-full bg-neutral px-1.5 text-[10px] text-neutral-content"
              >
                {length(visible_comments(@comments, false))}
              </span>
            </button>
          </div>
        </div>
      </header>

      <div class="flex min-h-0 flex-1">
        <div
          id="editor-root"
          phx-hook="ScreenplayEditor"
          phx-update="ignore"
          data-script-id={@script.id}
          data-updated-at={DateTime.to_unix(@script.updated_at)}
          data-content-version={@script.content_version}
          data-can-edit={to_string(Scripts.can_edit?(@role))}
          data-can-comment={to_string(Scripts.can_comment?(@role))}
          data-title={@script.title}
          data-user-email={@current_scope.user.email}
          class="relative flex min-h-0 flex-1"
        >
          <div id="scene-nav" class="scene-nav" hidden></div>
          <div class="editor-pane relative min-w-0 flex-1 border-r border-base-300">
            <textarea
              id="screenplay-input"
              spellcheck="false"
              autocomplete="off"
              readonly={!Scripts.can_edit?(@role)}
              placeholder={"INT. COFFEE SHOP - DAY\n\nStart writing. Scene headings, character names and dialogue are formatted automatically in the preview."}
              class="editor-textarea"
            >{@script.content}</textarea>
            <div id="autocomplete-menu" class="autocomplete-menu" hidden></div>
            <button
              :if={Scripts.can_edit?(@role)}
              id="tidy-button"
              class="tidy-button"
              title="Auto-format loose lines into scene headings, cues and dialogue"
            >
              <.icon name="hero-sparkles" class="size-3.5" /> Tidy
            </button>
          </div>
          <div class="pane-divider hidden md:flex">
            <button
              id="divider-left"
              type="button"
              onclick="moorlandUI.layoutLeft()"
              title="Hide the editor — distraction-free reading"
            >
              <.icon name="hero-chevron-left" class="size-3.5" />
            </button>
            <button
              id="divider-right"
              type="button"
              onclick="moorlandUI.layoutRight()"
              title="Hide the preview — distraction-free writing"
            >
              <.icon name="hero-chevron-right" class="size-3.5" />
            </button>
          </div>
          <div id="preview-wrap" class="preview-pane relative hidden min-w-0 flex-1 overflow-y-auto md:block">
            <div id="screenplay-preview" class="screenplay"></div>
            <div id="comment-bubble" class="comment-bubble" hidden>
              <button type="button" data-comment title="Comment on this selection">
                <.icon name="hero-chat-bubble-left" class="size-3.5" /> Comment
              </button>
              <button
                type="button"
                data-goto
                title="Jump to this spot in the editor (expands it if collapsed)"
              >
                <.icon name="hero-pencil-square" class="size-3.5" /> Go to
              </button>
            </div>
            <div id="helper-menu" class="autocomplete-menu" hidden></div>
          </div>
        </div>

        <aside
          :if={@panel}
          class="panel-aside flex w-80 shrink-0 flex-col overflow-y-auto border-l border-base-300 bg-base-100"
        >
          <.comments_panel
            :if={@panel == "comments"}
            comments={visible_comments(@comments, @show_resolved)}
            show_resolved={@show_resolved}
            anchor={@anchor}
            role={@role}
            current_user_id={@current_scope.user.id}
            script={@script}
          />
          <.notes_panel
            :if={@panel == "notes"}
            notes={@notes}
            role={@role}
            current_user_id={@current_scope.user.id}
          />
          <.bin_panel
            :if={@panel == "bin"}
            bin={@bin}
            shelf={@shelf}
            role={@role}
            current_user_id={@current_scope.user.id}
          />
          <.lookup_panel :if={@panel == "lookup"} q={@lookup_q} result={@lookup_result} />
          <.history_panel :if={@panel == "history"} versions={@versions} role={@role} />
          <.reports_panel
            :if={@panel == "reports"}
            stats={@stats}
            script={@script}
            role={@role}
            char_meta={@char_meta}
            sprint={@sprint}
          />
          <.share_panel
            :if={@panel == "share"}
            script={@script}
            collaborators={@collaborators}
            role={@role}
            peers={@peers}
            peer_shares={@peer_shares}
          />
        </aside>
      </div>

      <.diff_modal :if={@diff} diff={@diff} role={@role} />
      <.title_form_modal :if={@title_form} form={@title_form} />
    </div>

    <div id="print-root" class="screenplay print-screenplay" phx-update="ignore"></div>
    """
  end

  attr :comments, :list, required: true
  attr :show_resolved, :boolean, required: true
  attr :anchor, :any, required: true
  attr :role, :atom, required: true
  attr :current_user_id, :integer, required: true
  attr :script, :map, required: true

  defp comments_panel(assigns) do
    ~H"""
    <div class="flex flex-col">
      <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold">Comments</h2>
        <button
          phx-click="toggle_resolved"
          class="text-xs text-base-content/50 hover:text-base-content"
        >
          {if @show_resolved, do: "Hide resolved", else: "Show resolved"}
        </button>
      </div>

      <form
        :if={Scripts.can_comment?(@role)}
        id="add-comment-form"
        phx-submit="add_comment"
        class="border-b border-base-300 px-4 py-3"
      >
        <textarea
          name="body"
          rows="2"
          required
          placeholder="Add a comment…"
          class="textarea textarea-bordered w-full text-sm"
        ></textarea>
        <div class="mt-2 flex items-center justify-between gap-2">
          <label :if={@anchor} class="flex min-w-0 items-center gap-1.5 text-xs text-base-content/60">
            <input type="checkbox" name="anchored" value="true" checked class="checkbox checkbox-xs" />
            <span class="truncate">
              Line {@anchor.line + 1}<span :if={@anchor.text != ""}>: “{String.slice(@anchor.text, 0, 24)}”</span>
            </span>
          </label>
          <span :if={!@anchor} class="text-xs text-base-content/40">
            Highlight text in the preview or click a line to anchor
          </span>
          <button type="submit" class="btn btn-neutral btn-xs">Comment</button>
        </div>
      </form>

      <div class="divide-y divide-base-200">
        <div :for={comment <- @comments} class={["px-4 py-3", comment.resolved_at && "opacity-50"]}>
          <div class="flex items-start justify-between gap-2">
            <div class="min-w-0">
              <span class="text-xs font-semibold">{author_label(comment)}</span>
              <span
                :if={comment.remote_author}
                class="ml-1 text-[10px] text-base-content/40"
                title="Written on a peer installation"
              >
                via peer
              </span>
              <span class="ml-1 text-[11px] text-base-content/40">
                {time_ago(comment.inserted_at)}
              </span>
            </div>
            <div class="flex shrink-0 items-center gap-1">
              <button
                :if={Scripts.can_comment?(@role)}
                phx-click="resolve_comment"
                phx-value-id={comment.id}
                phx-value-resolved={to_string(is_nil(comment.resolved_at))}
                class="rounded p-0.5 text-base-content/40 hover:text-success"
                title={if comment.resolved_at, do: "Reopen", else: "Resolve"}
              >
                <.icon name="hero-check-circle" class="size-4" />
              </button>
              <button
                :if={comment.author_id == @current_user_id or @role == :owner}
                phx-click="delete_comment"
                phx-value-id={comment.id}
                data-confirm="Delete this comment thread?"
                class="rounded p-0.5 text-base-content/40 hover:text-error"
                title="Delete"
              >
                <.icon name="hero-trash" class="size-3.5" />
              </button>
            </div>
          </div>

          <button
            :if={comment.line_no}
            phx-click="jump_to_line"
            phx-value-line={comment.line_no}
            class="mt-1 block max-w-full truncate rounded bg-base-200 px-1.5 py-0.5 text-left font-mono text-[11px] text-base-content/60 hover:bg-base-300"
            title="Jump to line"
          >
            L{comment.line_no + 1} · {comment.anchor_text}
          </button>

          <p class="mt-1.5 whitespace-pre-wrap text-sm">{comment.body}</p>

          <div :for={reply <- comment.replies} class="mt-2 border-l-2 border-base-300 pl-3">
            <span class="text-xs font-semibold">{author_label(reply)}</span>
            <span
              :if={reply.remote_author}
              class="ml-1 text-[10px] text-base-content/40"
              title="Written on a peer installation"
            >
              via peer
            </span>
            <span class="ml-1 text-[11px] text-base-content/40">{time_ago(reply.inserted_at)}</span>
            <p class="mt-0.5 whitespace-pre-wrap text-sm">{reply.body}</p>
          </div>

          <form
            :if={Scripts.can_comment?(@role)}
            id={"reply-form-#{comment.id}"}
            phx-submit="reply_comment"
            class="mt-2 flex items-center gap-1.5"
          >
            <input type="hidden" name="parent_id" value={comment.id} />
            <input
              type="text"
              name="body"
              required
              placeholder="Reply…"
              autocomplete="off"
              class="input input-bordered input-xs flex-1"
            />
            <button type="submit" class="btn btn-ghost btn-xs">
              <.icon name="hero-paper-airplane" class="size-3.5" />
            </button>
          </form>
        </div>

        <p :if={@comments == []} class="px-4 py-8 text-center text-sm text-base-content/40">
          No comments yet.
        </p>
      </div>
    </div>
    """
  end

  attr :notes, :list, required: true
  attr :role, :atom, required: true
  attr :current_user_id, :integer, required: true

  defp notes_panel(assigns) do
    ~H"""
    <div class="flex flex-col">
      <div class="border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold">Notes</h2>
      </div>

      <form
        :if={Scripts.can_comment?(@role)}
        id="add-note-form"
        phx-submit="add_note"
        class="border-b border-base-300 px-4 py-3"
      >
        <textarea
          name="body"
          rows="2"
          required
          placeholder="Story ideas, research, reminders…"
          class="textarea textarea-bordered w-full text-sm"
        ></textarea>
        <div class="mt-2 flex items-center justify-between">
          <div class="flex gap-1.5">
            <label :for={color <- Moorland.Scripts.Note.colors()} class="cursor-pointer">
              <input
                type="radio"
                name="color"
                value={color}
                checked={color == "yellow"}
                class="peer sr-only"
              />
              <span class={[
                "block size-4 rounded-full border peer-checked:ring-2 peer-checked:ring-neutral peer-checked:ring-offset-1",
                note_color_class(color)
              ]}>
              </span>
            </label>
          </div>
          <button type="submit" class="btn btn-neutral btn-xs">Add note</button>
        </div>
      </form>

      <div class="space-y-3 p-4">
        <div
          :for={note <- @notes}
          class={["rounded-lg border p-3 shadow-sm", note_color_class(note.color)]}
        >
          <div class="flex items-start justify-between gap-2">
            <span class="text-[11px] font-semibold text-base-content/60">
              {author_label(note)}{if note.remote_author, do: " (via peer)"} · {time_ago(
                note.updated_at
              )}
            </span>
            <div class="flex shrink-0 gap-1">
              <button
                phx-click="toggle_pin"
                phx-value-id={note.id}
                phx-value-pinned={to_string(!note.pinned)}
                class={[
                  "rounded p-0.5 hover:text-base-content",
                  (note.pinned && "text-base-content") || "text-base-content/30"
                ]}
                title={if note.pinned, do: "Unpin", else: "Pin"}
              >
                <.icon name="hero-bookmark" class="size-3.5" />
              </button>
              <button
                :if={note.author_id == @current_user_id or @role == :owner}
                phx-click="delete_note"
                phx-value-id={note.id}
                data-confirm="Delete this note?"
                class="rounded p-0.5 text-base-content/30 hover:text-error"
                title="Delete"
              >
                <.icon name="hero-trash" class="size-3.5" />
              </button>
            </div>
          </div>
          <p class="mt-1.5 whitespace-pre-wrap text-sm">{note.body}</p>
        </div>

        <p :if={@notes == []} class="py-6 text-center text-sm text-base-content/40">
          No notes yet.
        </p>
      </div>
    </div>
    """
  end

  attr :bin, :list, required: true
  attr :shelf, :list, required: true
  attr :role, :atom, required: true
  attr :current_user_id, :integer, required: true

  defp bin_panel(assigns) do
    ~H"""
    <div class="flex flex-col">
      <div class="border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold">Bin &amp; Shelf</h2>
        <p class="mt-0.5 text-[11px] text-base-content/50">
          Cut text lands in the Bin instead of vanishing. The Shelf is yours across scripts.
        </p>
      </div>

      <div class="border-b border-base-300 px-4 py-3">
        <div class="flex items-center justify-between">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Bin — this script
          </h3>
          <button
            :if={Scripts.can_edit?(@role)}
            phx-click="bin_cut"
            class="btn btn-neutral btn-xs"
            title="Removes the selected editor text and keeps it here"
          >
            <.icon name="hero-scissors" class="size-3.5" /> Cut selection
          </button>
        </div>

        <div class="mt-2 space-y-2">
          <div :for={snippet <- @bin} class="rounded-lg border border-base-300 p-2.5">
            <p class="line-clamp-3 whitespace-pre-wrap font-mono text-[11px]">{snippet.body}</p>
            <div class="mt-1.5 flex items-center gap-1">
              <span class="mr-auto text-[10px] text-base-content/40">
                {snippet.user.email |> String.split("@") |> hd()} · {time_ago(snippet.inserted_at)}
              </span>
              <button
                :if={Scripts.can_edit?(@role)}
                phx-click="snippet_insert"
                phx-value-id={snippet.id}
                class="btn btn-ghost btn-xs"
                title="Insert at the cursor"
              >
                Insert
              </button>
              <button
                :if={snippet.user_id == @current_user_id}
                phx-click="snippet_shelf"
                phx-value-id={snippet.id}
                class="btn btn-ghost btn-xs"
                title="Move to your Shelf"
              >
                Shelf
              </button>
              <button
                phx-click="snippet_delete"
                phx-value-id={snippet.id}
                data-confirm="Delete this snippet for good?"
                class="rounded p-0.5 text-base-content/40 hover:text-error"
              >
                <.icon name="hero-trash" class="size-3.5" />
              </button>
            </div>
          </div>
          <p :if={@bin == []} class="py-3 text-center text-xs text-base-content/40">
            Select text in the editor, then “Cut selection”.
          </p>
        </div>
      </div>

      <div class="px-4 py-3">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
          Shelf — yours, everywhere
        </h3>
        <form id="shelf-add-form" phx-submit="shelf_add" class="mt-2 flex gap-1.5">
          <input
            type="text"
            name="body"
            required
            placeholder="Keep a line for later…"
            autocomplete="off"
            class="input input-bordered input-xs flex-1"
          />
          <button type="submit" class="btn btn-ghost btn-xs">Add</button>
        </form>

        <div class="mt-2 space-y-2">
          <div :for={snippet <- @shelf} class="rounded-lg border border-base-300 p-2.5">
            <p class="line-clamp-3 whitespace-pre-wrap font-mono text-[11px]">{snippet.body}</p>
            <div class="mt-1.5 flex items-center gap-1">
              <span class="mr-auto text-[10px] text-base-content/40">
                {time_ago(snippet.inserted_at)}
              </span>
              <button
                :if={Scripts.can_edit?(@role)}
                phx-click="snippet_insert"
                phx-value-id={snippet.id}
                class="btn btn-ghost btn-xs"
              >
                Insert
              </button>
              <button
                phx-click="snippet_delete"
                phx-value-id={snippet.id}
                data-confirm="Delete this snippet for good?"
                class="rounded p-0.5 text-base-content/40 hover:text-error"
              >
                <.icon name="hero-trash" class="size-3.5" />
              </button>
            </div>
          </div>
          <p :if={@shelf == []} class="py-3 text-center text-xs text-base-content/40">
            Nothing shelved yet.
          </p>
        </div>
      </div>
    </div>
    """
  end

  attr :q, :string, required: true
  attr :result, :any, required: true

  defp lookup_panel(assigns) do
    ~H"""
    <div class="flex flex-col">
      <div class="border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold">Lookup</h2>
      </div>

      <form id="lookup-form" phx-submit="lookup" class="flex gap-1.5 border-b border-base-300 px-4 py-3">
        <input
          type="text"
          name="q"
          value={@q}
          required
          placeholder="A word…"
          autocomplete="off"
          class="input input-bordered input-sm flex-1"
        />
        <button type="submit" class="btn btn-neutral btn-sm">
          <.icon name="hero-magnifying-glass" class="size-4" />
        </button>
      </form>

      <div class="p-4">
        <%= case @result do %>
          <% nil -> %>
            <p class="py-4 text-center text-sm text-base-content/40">
              Definitions, synonyms and rhymes — without leaving the draft.
            </p>
          <% {:error, _} -> %>
            <p class="py-4 text-center text-sm text-base-content/40">
              Lookup needs an internet connection.
            </p>
          <% {:ok, data} -> %>
            <div :if={data.definitions != []}>
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Definitions
              </h3>
              <ol class="mt-1.5 space-y-1.5 text-sm">
                <li :for={{pos, text} <- data.definitions}>
                  <span :if={pos != ""} class="mr-1 text-[10px] italic text-base-content/50">
                    {pos}
                  </span>{text}
                </li>
              </ol>
            </div>
            <div :if={data.synonyms != []} class="mt-4">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Synonyms
              </h3>
              <p class="mt-1 text-sm">{Enum.join(data.synonyms, " · ")}</p>
            </div>
            <div :if={data.rhymes != []} class="mt-4">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Rhymes
              </h3>
              <p class="mt-1 text-sm">{Enum.join(data.rhymes, " · ")}</p>
            </div>
            <p
              :if={data.definitions == [] and data.synonyms == [] and data.rhymes == []}
              class="py-4 text-center text-sm text-base-content/40"
            >
              Nothing found for “{data.word}”.
            </p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :versions, :list, required: true
  attr :role, :atom, required: true

  defp history_panel(assigns) do
    ~H"""
    <div class="flex flex-col">
      <div class="border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold">History</h2>
        <p class="mt-0.5 text-[11px] text-base-content/50">
          Auto-snapshots are taken every 10 minutes while writing.
        </p>
      </div>

      <form
        :if={Scripts.can_edit?(@role)}
        id="snapshot-form"
        phx-submit="snapshot"
        class="flex gap-1.5 border-b border-base-300 px-4 py-3"
      >
        <input
          type="text"
          name="message"
          placeholder="Snapshot name (e.g. “First draft”)"
          autocomplete="off"
          class="input input-bordered input-sm flex-1"
        />
        <button type="submit" class="btn btn-neutral btn-sm" title="Snapshot current version">
          <.icon name="hero-camera" class="size-4" />
        </button>
      </form>

      <div class="divide-y divide-base-200">
        <div :for={version <- @versions} class="px-4 py-3">
          <div class="flex items-center gap-2">
            <span class={[
              "rounded px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide",
              version.kind == "manual" && "bg-neutral text-neutral-content",
              version.kind == "auto" && "bg-base-200 text-base-content/60",
              version.kind == "restore" && "bg-amber-100 text-amber-800"
            ]}>
              {version.kind}
            </span>
            <span class="text-[11px] text-base-content/40">{time_ago(version.inserted_at)}</span>
          </div>
          <div class="mt-1 text-sm font-medium">
            {version.message || Calendar.strftime(version.inserted_at, "%b %d, %H:%M")}
          </div>
          <div :if={version.author || version.remote_author} class="text-[11px] text-base-content/50">
            by {author_label(version)}{if version.remote_author, do: " (via peer)"}
          </div>
          <div class="mt-1.5 flex gap-1.5">
            <button
              phx-click="show_diff"
              phx-value-version-id={version.id}
              class="btn btn-ghost btn-xs"
            >
              Compare
            </button>
            <button
              :if={Scripts.can_edit?(@role)}
              phx-click="restore"
              phx-value-version-id={version.id}
              data-confirm="Restore this version? Your current text is snapshotted first, so nothing is lost."
              class="btn btn-ghost btn-xs"
            >
              Restore
            </button>
          </div>
        </div>

        <p :if={@versions == []} class="px-4 py-8 text-center text-sm text-base-content/40">
          No versions yet. Save a snapshot to mark a milestone.
        </p>
      </div>
    </div>
    """
  end

  defp gender_balance(characters, char_meta) do
    totals =
      Enum.reduce(characters, %{}, fn char, acc ->
        gender = Map.get(char_meta, char.name, "unspecified")
        Map.update(acc, gender, char.words, &(&1 + char.words))
      end)

    total = totals |> Map.values() |> Enum.sum()

    if total > 0 and map_size(Map.delete(totals, "unspecified")) > 0 do
      labels = %{
        "female" => "Female",
        "male" => "Male",
        "nonbinary" => "Non-binary",
        "unspecified" => "Untagged"
      }

      ~w(female male nonbinary unspecified)
      |> Enum.flat_map(fn key ->
        case totals[key] do
          nil -> []
          words -> [{labels[key], round(words / total * 100)}]
        end
      end)
    end
  end

  attr :stats, :map, required: true
  attr :script, :map, required: true
  attr :role, :atom, required: true
  attr :char_meta, :map, required: true
  attr :sprint, :any, required: true

  defp reports_panel(assigns) do
    ~H"""
    <div class="flex flex-col">
      <div class="border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold">Reports</h2>
        <p class="mt-0.5 text-[11px] text-base-content/50">
          Estimates use the standard page ≈ one minute of screen time.
        </p>
      </div>

      <div :if={@stats} class="p-4">
        <div class="mb-4 rounded-lg border border-base-300 px-3 py-2.5">
          <div class="flex items-center justify-between">
            <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
              Writing sprint
            </h3>
            <div :if={!@sprint} class="flex gap-1">
              <button
                :for={mins <- [5, 15, 25]}
                phx-click="sprint_start"
                phx-value-mins={mins}
                class="btn btn-ghost btn-xs"
              >
                {mins}m
              </button>
            </div>
            <button :if={@sprint} phx-click="sprint_stop" class="btn btn-ghost btn-xs text-error">
              Stop
            </button>
          </div>
          <div :if={@sprint} class="mt-1.5">
            <div class="flex justify-between text-sm tabular-nums">
              <span class="font-semibold">
                {div(@sprint.remaining, 60)}:{@sprint.remaining
                |> rem(60)
                |> Integer.to_string()
                |> String.pad_leading(2, "0")}
              </span>
              <span class="text-base-content/60">
                {max(@stats.words - @sprint.start_words, 0)} words this sprint
              </span>
            </div>
            <div class="mt-1 h-1 rounded-full bg-base-200">
              <div
                class="h-1 rounded-full bg-neutral"
                style={"width: #{(1 - @sprint.remaining / (@sprint.mins * 60)) * 100}%"}
              >
              </div>
            </div>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-2">
          <div
            :for={
              {value, label} <- [
                {@stats.pages, "pages"},
                {"#{@stats.minutes} min", "est. runtime"},
                {@stats.scene_count, "scenes"},
                {@stats.words, "words"}
              ]
            }
            class="rounded-lg border border-base-300 px-3 py-2.5"
          >
            <div class="text-lg font-semibold tabular-nums">{value}</div>
            <div class="text-[11px] text-base-content/50">{label}</div>
          </div>
        </div>

        <div :if={Scripts.can_edit?(@role) or @script.goal_words || @script.goal_pages} class="mt-5">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Goals
          </h3>
          <form
            :if={Scripts.can_edit?(@role)}
            id="goals-form"
            phx-change="set_goals"
            class="mt-2 flex gap-2"
          >
            <label class="flex-1">
              <span class="text-[11px] text-base-content/50">Words</span>
              <input
                type="number"
                name="goal_words"
                value={@script.goal_words}
                min="0"
                placeholder="—"
                phx-debounce="600"
                class="input input-bordered input-xs w-full"
              />
            </label>
            <label class="flex-1">
              <span class="text-[11px] text-base-content/50">Pages</span>
              <input
                type="number"
                name="goal_pages"
                value={@script.goal_pages}
                min="0"
                placeholder="—"
                phx-debounce="600"
                class="input input-bordered input-xs w-full"
              />
            </label>
          </form>
          <div
            :for={
              {label, current, goal} <- [
                {"words", @stats.words, @script.goal_words},
                {"pages", @stats.pages, @script.goal_pages}
              ]
            }
            :if={goal}
            class="mt-2"
          >
            <div class="flex justify-between text-[11px] text-base-content/50">
              <span>{current} / {goal} {label}</span>
              <span>{min(100, round(current / max(goal, 1) * 100))}%</span>
            </div>
            <div class="mt-0.5 h-1 rounded-full bg-base-200">
              <div
                class={[
                  "h-1 rounded-full",
                  (current >= goal && "bg-success") || "bg-neutral"
                ]}
                style={"width: #{min(100, current / max(goal, 1) * 100)}%"}
              >
              </div>
            </div>
          </div>
        </div>

        <div :if={@stats.characters != []} class="mt-5">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Speaking parts
          </h3>
          <% max_words = @stats.characters |> Enum.map(& &1.words) |> Enum.max() |> max(1) %>
          <div class="mt-2 space-y-2">
            <div :for={char <- Enum.take(@stats.characters, 8)}>
              <div class="flex items-baseline justify-between gap-2">
                <span class="truncate font-mono text-xs">{char.name}</span>
                <form
                  :if={Scripts.can_edit?(@role)}
                  id={"gender-form-#{Base.url_encode64(char.name, padding: false)}"}
                  phx-change="set_gender"
                  class="shrink-0"
                >
                  <input type="hidden" name="name" value={char.name} />
                  <select
                    name="gender"
                    class="select select-ghost select-xs w-16 text-[10px] text-base-content/50"
                  >
                    <option
                      :for={
                        {value, label} <- [
                          {"unspecified", "—"},
                          {"female", "F"},
                          {"male", "M"},
                          {"nonbinary", "NB"}
                        ]
                      }
                      value={value}
                      selected={Map.get(@char_meta, char.name, "unspecified") == value}
                    >
                      {label}
                    </option>
                  </select>
                </form>
                <span class="shrink-0 text-[11px] tabular-nums text-base-content/50">
                  {char.lines} {if char.lines == 1, do: "line", else: "lines"} · {char.words} words
                </span>
              </div>
              <div class="mt-0.5 h-1 rounded-full bg-base-200">
                <div
                  class="h-1 rounded-full bg-neutral"
                  style={"width: #{Float.round(char.words / max_words * 100, 1)}%"}
                >
                </div>
              </div>
            </div>
          </div>

          <% balance = gender_balance(@stats.characters, @char_meta) %>
          <p :if={balance} class="mt-2 text-[11px] text-base-content/60">
            Dialogue balance: {balance
            |> Enum.map(fn {label, pct} -> "#{label} #{pct}%" end)
            |> Enum.join(" · ")}
          </p>
        </div>

        <div :if={@stats.scene_count > 0} class="mt-5">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Scene mix
          </h3>
          <p class="mt-1.5 text-xs text-base-content/70">
            INT {@stats.int_ext.int} · EXT {@stats.int_ext.ext}<span :if={@stats.int_ext.other > 0}> · other {@stats.int_ext.other}</span>
          </p>
          <p class="mt-1 text-xs text-base-content/70">
            {@stats.times
            |> Enum.map(fn {label, count} -> "#{label} #{count}" end)
            |> Enum.join(" · ")}
          </p>
        </div>

        <div :if={@stats.locations != []} class="mt-5">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Locations
          </h3>
          <div class="mt-1.5 space-y-1">
            <div
              :for={{name, count} <- Enum.take(@stats.locations, 8)}
              class="flex items-baseline justify-between gap-2 text-xs"
            >
              <span class="truncate font-mono">{name}</span>
              <span class="shrink-0 tabular-nums text-base-content/50">×{count}</span>
            </div>
          </div>
        </div>

        <p :if={@stats.scene_count == 0 and @stats.words == 0} class="py-6 text-center text-sm text-base-content/40">
          Statistics appear once there is something to count.
        </p>
      </div>
    </div>
    """
  end

  attr :script, :map, required: true
  attr :collaborators, :list, required: true
  attr :role, :atom, required: true
  attr :peers, :list, required: true
  attr :peer_shares, :map, required: true

  defp share_panel(assigns) do
    ~H"""
    <div class="flex flex-col">
      <div class="border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold">Sharing</h2>
      </div>

      <div
        :if={@script.origin_public_key}
        class="border-b border-base-300 px-4 py-3 text-xs text-base-content/60"
      >
        <.icon name="hero-signal" class="size-3.5" />
        This is a synced copy from a peer installation ({@script.origin_role || "editor"} access).
        Your edits merge back automatically while the peer is reachable.
      </div>

      <form
        :if={@role == :owner}
        id="add-collaborator-form"
        phx-submit="add_collaborator"
        class="space-y-2 border-b border-base-300 px-4 py-3"
      >
        <input
          type="email"
          name="email"
          required
          placeholder="collaborator@example.com"
          autocomplete="off"
          class="input input-bordered input-sm w-full"
        />
        <div class="flex gap-1.5">
          <select name="role" class="select select-bordered select-sm flex-1">
            <option value="editor">Editor — can write</option>
            <option value="commenter">Commenter — comments &amp; notes only</option>
            <option value="viewer">Viewer — read only</option>
          </select>
          <button type="submit" class="btn btn-neutral btn-sm">Invite</button>
        </div>
      </form>

      <div class="divide-y divide-base-200">
        <div class="flex items-center justify-between px-4 py-3">
          <div class="min-w-0">
            <div class="truncate text-sm">{@script.owner.email}</div>
          </div>
          <span class="text-[11px] font-medium uppercase tracking-wide text-base-content/50">
            Owner
          </span>
        </div>

        <div :for={collab <- @collaborators} class="flex items-center justify-between gap-2 px-4 py-3">
          <div class="min-w-0 flex-1 truncate text-sm">{collab.user.email}</div>
          <form :if={@role == :owner} id={"role-form-#{collab.id}"} phx-change="update_role" class="shrink-0">
            <input type="hidden" name="collab_id" value={collab.id} />
            <select name="role" class="select select-bordered select-xs">
              <option :for={r <- Moorland.Scripts.Collaborator.roles()} value={r} selected={collab.role == r}>
                {String.capitalize(r)}
              </option>
            </select>
          </form>
          <span :if={@role != :owner} class="text-[11px] uppercase text-base-content/50">
            {collab.role}
          </span>
          <button
            :if={@role == :owner}
            phx-click="remove_collaborator"
            phx-value-id={collab.id}
            data-confirm={"Remove #{collab.user.email} from this script?"}
            class="rounded p-0.5 text-base-content/40 hover:text-error"
            title="Remove"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </div>

      <div
        :if={@role == :owner and is_nil(@script.origin_public_key) and @peers != []}
        class="border-t border-base-300 px-4 py-3"
      >
        <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
          Peer installations
        </h3>
        <p class="mt-0.5 text-[11px] text-base-content/50">
          Shared peers mirror this script on their machine and sync directly with yours.
        </p>
        <div class="mt-2 space-y-2">
          <div :for={peer <- @peers} class="flex items-center justify-between gap-2">
            <span class="min-w-0 flex-1 truncate text-sm">{peer.name}</span>
            <form id={"peer-share-#{peer.id}"} phx-change="set_peer_share" class="shrink-0">
              <input type="hidden" name="peer_id" value={peer.id} />
              <select name="role" class="select select-bordered select-xs">
                <option value="" selected={!Map.has_key?(@peer_shares, peer.id)}>Not shared</option>
                <option value="editor" selected={@peer_shares[peer.id] == "editor"}>Editor</option>
                <option value="viewer" selected={@peer_shares[peer.id] == "viewer"}>Viewer</option>
              </select>
            </form>
          </div>
        </div>
      </div>

      <div
        :if={@role == :owner and is_nil(@script.origin_public_key) and @peers == []}
        class="border-t border-base-300 px-4 py-3 text-[11px] text-base-content/50"
      >
        Add peer installations on the
        <.link navigate={~p"/peers"} class="underline">Peers page</.link>
        to collaborate directly, machine to machine.
      </div>
    </div>
    """
  end

  attr :form, :map, required: true

  defp title_form_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-6" phx-click="close_title_form">
      <div
        class="w-full max-w-md overflow-hidden rounded-xl bg-base-100 shadow-2xl"
        phx-click-away="close_title_form"
      >
        <div class="flex items-center justify-between border-b border-base-300 px-5 py-3">
          <h3 class="text-sm font-semibold">Title page</h3>
          <button phx-click="close_title_form" class="rounded p-1 hover:bg-base-200">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <form id="title-page-form" phx-submit="apply_title_page" class="space-y-2.5 p-5">
          <label :for={
            {key, label, placeholder} <- [
              {"title", "Title", "The name of the script"},
              {"credit", "Credit", "Written by"},
              {"author", "Author", "Your name"},
              {"source", "Based on", "Optional source material"},
              {"draft_date", "Draft date", "Optional"},
              {"copyright", "Copyright", "Optional"}
            ]
          } class="block">
            <span class="text-[11px] text-base-content/50">{label}</span>
            <input
              type="text"
              name={key}
              value={@form[key]}
              placeholder={placeholder}
              autocomplete="off"
              class="input input-bordered input-sm w-full"
            />
          </label>
          <label class="block">
            <span class="text-[11px] text-base-content/50">Contact (one line per row)</span>
            <textarea
              name="contact"
              rows="2"
              placeholder="you@example.com"
              class="textarea textarea-bordered w-full text-sm"
            >{@form["contact"]}</textarea>
          </label>
          <div class="flex justify-end gap-2 pt-1">
            <button type="button" phx-click="close_title_form" class="btn btn-ghost btn-sm">
              Cancel
            </button>
            <button type="submit" class="btn btn-neutral btn-sm">Apply</button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :diff, :map, required: true
  attr :role, :atom, required: true

  defp diff_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-6" phx-click="close_diff">
      <div
        class="flex max-h-full w-full max-w-3xl flex-col overflow-hidden rounded-xl bg-base-100 shadow-2xl"
        phx-click-away="close_diff"
      >
        <div class="flex items-center justify-between border-b border-base-300 px-5 py-3">
          <div>
            <h3 class="text-sm font-semibold">
              {@diff.version.message ||
                Calendar.strftime(@diff.version.inserted_at, "%b %d, %Y %H:%M")} → current
            </h3>
            <p class="text-[11px] text-base-content/50">
              <span class="text-error">removed</span> lines were in the version;
              <span class="text-success">added</span> lines are in the current draft.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <button
              :if={Scripts.can_edit?(@role)}
              phx-click="restore"
              phx-value-version-id={@diff.version.id}
              data-confirm="Restore this version? Your current text is snapshotted first."
              class="btn btn-neutral btn-xs"
            >
              Restore this version
            </button>
            <button phx-click="close_diff" class="rounded p-1 hover:bg-base-200">
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>
        <div class="overflow-y-auto p-4 font-mono text-xs leading-5">
          <div
            :for={{op, line} <- @diff.lines}
            class={[
              "whitespace-pre-wrap px-2",
              op == :del && "bg-red-50 text-red-800 dark:bg-red-950/40 dark:text-red-300",
              op == :ins &&
                "bg-emerald-50 text-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-300"
            ]}
          ><span class="select-none pr-2 text-base-content/30">{case op do
              :del -> "-"
              :ins -> "+"
              :eq -> " "
            end}</span>{if line == "", do: " ", else: line}</div>
        </div>
      </div>
    </div>
    """
  end
end
