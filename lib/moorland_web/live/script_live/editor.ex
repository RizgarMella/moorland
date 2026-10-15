defmodule MoorlandWeb.ScriptLive.Editor do
  use MoorlandWeb, :live_view

  import MoorlandWeb.BreakdownComponents, only: [breakdown_panel: 1, scene_for_line: 2]

  import MoorlandWeb.CharacterComponents, only: [characters_tab: 1]
  import MoorlandWeb.ProseReportComponents, only: [prose_report: 1]
  import MoorlandWeb.SuggestionComponents, only: [suggestions_section: 1]

  import MoorlandWeb.RevisionComponents,
    only: [revision_chip: 1, revision_section: 1, revision_label: 1]

  alias Moorland.Scripts
  alias Moorland.Scripts.{Breakdown, Stats}
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
        tag_draft: nil,
        breakdown: nil,
        notes_kind: "note",
        prose_report: nil,
        open_suggestion: nil,
        characters: [],
        editing_sheet: nil,
        lineage: if(script.stage, do: Scripts.lineage(scope, script), else: []),
        tags: Scripts.list_breakdown_tags(script),
        revision_sets: Scripts.list_revision_sets(script),
        revision_shown: nil,
        presences: presence_list(script.id)
      )
      |> load_panel_data()
      |> push_tags()
      |> push_revision()
      |> push_page_lock()

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
      peer_routes: Scripts.list_peer_routes(script),
      bin: Scripts.list_bin(script),
      suggestions: Scripts.list_open_suggestions(script),
      shelf: Scripts.list_shelf(socket.assigns.current_scope)
    )
  end

  # The preview highlights tagged words; the hook finds them itself, near
  # the recorded line, so highlights follow text as it moves while typing.
  defp push_tags(socket) do
    tags =
      for tag <- socket.assigns.tags, tag.anchor_text do
        %{text: tag.anchor_text, line: tag.line_no, category: tag.category, name: tag.name}
      end

    push_event(socket, "breakdown_tags", %{tags: tags})
  end

  # The revision set whose changes are marked: the one picked in History,
  # else the latest. Nil outside revision mode.
  defp shown_revision(%{revision_sets: []}), do: nil

  defp shown_revision(%{revision_sets: sets, revision_shown: id}),
    do: Enum.find(sets, List.last(sets), &(&1.id == id))

  defp push_revision(socket) do
    payload =
      case shown_revision(socket.assigns) do
        nil ->
          %{}

        set ->
          %{
            base: set.base_content,
            color: Moorland.Scripts.RevisionSet.color_key(set.color),
            label: revision_label(set)
          }
      end

    push_event(socket, "revision", payload)
  end

  defp push_page_lock(socket),
    do: push_event(socket, "page_lock", %{lock: socket.assigns.script.page_lock})

  defp build_breakdown(socket) do
    if socket.assigns.panel == "breakdown",
      do:
        assign(
          socket,
          :breakdown,
          Breakdown.build(socket.assigns.script.content, socket.assigns.tags)
        ),
      else: assign(socket, :breakdown, nil)
  end

  # Characters are worked out only while their tab is open.
  defp load_characters(%{assigns: %{panel: "notes", notes_kind: "character"}} = socket) do
    assign(
      socket,
      :characters,
      MoorlandWeb.CharacterComponents.rows(socket.assigns.script, socket.assigns.notes)
    )
  end

  defp load_characters(socket), do: socket

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

  def handle_event("tag_selection", %{"line" => line, "text" => text}, socket) do
    {:noreply,
     socket
     |> assign(tag_draft: %{line: line, text: String.trim(text)}, panel: "breakdown")
     |> build_breakdown()}
  end

  def handle_event("create_tag", params, socket) do
    %{current_scope: scope, script: script, tag_draft: draft} = socket.assigns

    attrs = %{
      category: params["category"],
      name: params["name"],
      anchor_text: draft && draft.text,
      line_no: draft && draft.line
    }

    case draft && Scripts.create_breakdown_tag(scope, script, attrs) do
      {:ok, _tag} ->
        {:noreply, assign(socket, :tag_draft, nil)}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "You can't tag this script.")}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Give the element a name.")}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("shot_selection", %{"line" => line, "text" => text}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    text = String.trim(text)
    attrs = %{anchor_text: text, line_no: line, description: String.slice(text, 0, 2000)}

    case Scripts.create_shot(scope, script, attrs) do
      {:ok, _shot} -> {:noreply, put_flash(socket, :info, "Shot added to the shot list.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not add that shot.")}
    end
  end

  def handle_event("cancel_tag", _params, socket) do
    {:noreply, assign(socket, :tag_draft, nil)}
  end

  def handle_event("remove_tags", %{"ids" => ids}, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    for id <- String.split(ids, ",", trim: true),
        do: Scripts.delete_breakdown_tag(scope, script, id)

    {:noreply, socket}
  end

  def handle_event("lock_pages", %{"base" => base, "pages" => pages}, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    case Scripts.lock_pages(scope, script, base, pages) do
      {:ok, script} ->
        {:noreply,
         socket
         |> assign(:script, script)
         |> push_page_lock()
         |> put_flash(:info, "Pages locked. Additions now run on to A-pages.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not lock the pages.")}
    end
  end

  def handle_event("unlock_pages", _params, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    case Scripts.unlock_pages(scope, script) do
      {:ok, script} -> {:noreply, socket |> assign(:script, script) |> push_page_lock()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not unlock the pages.")}
    end
  end

  def handle_event("toggle_suggestion", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {id, ""} -> {:noreply, update(socket, :open_suggestion, &if(&1 == id, do: nil, else: id))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("apply_suggestion", %{"id" => id}, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    case Scripts.apply_suggestion(scope, script, id) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> assign(:script, saved)
         |> push_event("remote_content", %{content: saved.content, version: saved.content_version})
         |> put_flash(:info, "Suggestion applied.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not apply that suggestion.")}
    end
  end

  def handle_event("dismiss_suggestion", %{"id" => id}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.dismiss_suggestion(scope, script, id)
    {:noreply, socket}
  end

  def handle_event("start_revision", _params, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    case Scripts.start_revision(scope, script) do
      {:ok, set} -> {:noreply, put_flash(socket, :info, "#{set.color} revision started.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Only editors can start a revision.")}
    end
  end

  def handle_event("show_revision", %{"id" => id}, socket) do
    shown = Enum.find(socket.assigns.revision_sets, &(to_string(&1.id) == id))

    {:noreply,
     socket
     |> assign(:revision_shown, shown && shown.id)
     |> push_revision()}
  end

  def handle_event("clear_revisions", _params, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    Scripts.clear_revisions(scope, script)
    {:noreply, socket}
  end

  def handle_event("start_next_stage", _params, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    case Scripts.start_next_stage(scope, script) do
      {:ok, next} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{Moorland.Scripts.Pipeline.label(next.stage)} started from this.")
         |> push_navigate(to: ~p"/scripts/#{next.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not start the next stage.")}
    end
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

    socket =
      socket |> assign(panel: new_panel, diff: nil) |> build_breakdown() |> load_characters()

    if new_panel == "comments" do
      Scripts.mark_notifications_read(socket.assigns.current_scope, socket.assigns.script)
    end

    socket =
      if new_panel == "reports",
        do:
          assign(socket,
            stats: Stats.compute_for(socket.assigns.script, socket.assigns.script.content),
            prose_report: prose_report_for(socket.assigns.script, socket.assigns.script.content),
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
       start_words: Stats.compute_for(socket.assigns.script, socket.assigns.script.content).words,
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

  def handle_event("add_note", %{"body" => body, "color" => color} = params, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    kind = if params["kind"] == "sketch", do: "sketch", else: "note"

    case Scripts.create_note(scope, script, %{body: body, color: color, kind: kind}) do
      {:ok, _} -> {:noreply, load_panel_data(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not add the note.")}
    end
  end

  def handle_event("notes_kind", %{"kind" => kind}, socket) do
    kind = if kind in ["sketch", "character"], do: kind, else: "note"
    {:noreply, socket |> assign(:notes_kind, kind) |> load_characters()}
  end

  def handle_event("add_sheet", %{"name" => name}, socket) do
    %{current_scope: scope, script: script} = socket.assigns
    body = MoorlandWeb.CharacterComponents.sheet_template(name)

    case Scripts.create_note(scope, script, %{body: body, kind: "character", color: "gray"}) do
      {:ok, note} ->
        {:noreply,
         socket |> assign(:editing_sheet, note.id) |> load_panel_data() |> load_characters()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not add that sheet.")}
    end
  end

  def handle_event("edit_sheet", %{"id" => id}, socket) do
    id =
      case Integer.parse(id) do
        {n, ""} -> n
        _ -> nil
      end

    {:noreply, assign(socket, :editing_sheet, id)}
  end

  def handle_event("save_sheet", %{"note_id" => id, "body" => body}, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    case Scripts.update_note(scope, script, id, %{body: body}) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(:editing_sheet, nil) |> load_panel_data() |> load_characters()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That sheet couldn't be saved.")}
    end
  end

  def handle_event("script_from_sketch", %{"id" => id}, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    case Scripts.start_script_from_sketch(scope, script, id) do
      {:ok, new_script} ->
        {:noreply,
         socket
         |> put_flash(:info, "New script started from the sketch.")
         |> push_navigate(to: ~p"/scripts/#{new_script.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not start a script from that sketch.")}
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

  def handle_event("set_peer_share", %{"peer_id" => peer_id, "role" => role} = params, socket) do
    %{current_scope: scope, script: script} = socket.assigns

    socket =
      case Scripts.set_peer_share(
             scope,
             script,
             String.to_integer(peer_id),
             role,
             params["studio_peer_id"]
           ) do
        {:error, :not_a_studio} -> put_flash(socket, :error, "That peer isn't a studio.")
        _ -> socket
      end

    {:noreply, load_panel_data(socket)}
  end

  ## Event helpers

  defp parse_goal(value) do
    case Integer.parse(to_string(value || "")) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
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
          [
            "Contact:"
            | value
              |> String.split(~r/\r?\n/, trim: true)
              |> Enum.map(&("    " <> String.trim(&1)))
          ]
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

  ## PubSub & timers

  @impl true
  def handle_info(:sprint_tick, socket) do
    case socket.assigns.sprint do
      nil ->
        {:noreply, socket}

      sprint ->
        remaining = sprint.ends_at - System.system_time(:second)

        words =
          Stats.compute_for(socket.assigns.script, socket.assigns.script.content).words -
            sprint.start_words

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
        do:
          assign(socket,
            stats: Stats.compute_for(socket.assigns.script, content),
            prose_report: prose_report_for(socket.assigns.script, content)
          ),
        else: socket

    socket = socket |> build_breakdown() |> load_characters()

    if user_id != socket.assigns.current_scope.user.id do
      {:noreply, push_event(socket, "remote_content", %{content: content, version: version})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:script_updated, _id}, socket) do
    {script, role} = Scripts.get_script!(socket.assigns.current_scope, socket.assigns.script.id)

    {:noreply,
     socket |> assign(script: script, role: role, page_title: script.title) |> push_page_lock()}
  end

  def handle_info({event, _id}, socket)
      when event in [
             :comments_changed,
             :notes_changed,
             :versions_changed,
             :collaborators_changed,
             :suggestions_changed
           ] do
    {:noreply, socket |> load_panel_data() |> load_characters()}
  end

  def handle_info({:revisions_changed, _id}, socket) do
    {:noreply,
     socket
     |> assign(
       revision_sets: Scripts.list_revision_sets(socket.assigns.script),
       revision_shown: nil
     )
     |> push_revision()}
  end

  def handle_info({:breakdown_changed, _id}, socket) do
    {:noreply,
     socket
     |> assign(:tags, Scripts.list_breakdown_tags(socket.assigns.script))
     |> build_breakdown()
     |> push_tags()}
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

  # Marks what an AI assistant peer wrote, wherever it is shown.
  defp assistant_badge(assigns) do
    ~H"""
    <span
      class="ml-1 rounded bg-primary/15 px-1 py-px text-[9px] font-semibold uppercase tracking-wide text-primary"
      title="Written by an AI assistant connected as a peer"
    >
      AI
    </span>
    """
  end

  defp prose?(script), do: Moorland.Scripts.Script.prose?(script)

  defp prose_report_for(script, content),
    do: if(prose?(script), do: Moorland.Scripts.ProseReport.analyze(content))

  # The story-to-script pipeline this document belongs to: every stage, the
  # documents at each (linked), this one marked, and the way to the next.
  attr :script, :map, required: true
  attr :lineage, :list, required: true

  defp stages_strip(assigns) do
    alias Moorland.Scripts.Pipeline

    assigns =
      assign(assigns,
        stages: Pipeline.stages(),
        by_stage: Enum.group_by(assigns.lineage, & &1.stage),
        next: Pipeline.next(assigns.script.stage)
      )

    ~H"""
    <nav
      id="stages-strip"
      aria-label="Pipeline stages"
      class="flex shrink-0 items-center gap-1 overflow-x-auto border-b border-base-300 bg-base-200/40 px-3 py-1.5 text-xs"
    >
      <%= for {{stage, label}, i} <- Enum.with_index(@stages) do %>
        <.icon :if={i > 0} name="hero-chevron-right" class="size-3 shrink-0 text-base-content/30" />
        <% docs = Map.get(@by_stage, stage, []) %>
        <span
          :if={docs == []}
          class="shrink-0 rounded-full px-2 py-0.5 text-base-content/35"
        >
          {label}
        </span>
        <.link
          :for={doc <- docs}
          navigate={~p"/scripts/#{doc.id}"}
          class={[
            "shrink-0 rounded-full px-2 py-0.5 transition",
            doc.id == @script.id && "bg-neutral font-medium text-neutral-content",
            doc.id != @script.id && "text-base-content/70 hover:bg-base-300"
          ]}
          aria-current={doc.id == @script.id && "page"}
        >
          {label}
        </.link>
      <% end %>
      <button
        :if={@next}
        id="start-next-stage"
        type="button"
        phx-click="start_next_stage"
        class="ml-auto shrink-0 rounded-md px-2 py-0.5 font-medium text-base-content/70 transition hover:bg-base-300 hover:text-base-content"
        title={
          if @next == "script",
            do: "Open a script with a scene stub for every scene, the story kept beside each",
            else: "Open a copy of this to grow into the next stage"
        }
      >
        Start the {String.downcase(Pipeline.label(@next))} →
      </button>
    </nav>
    """
  end

  defp podcast?(script), do: Moorland.Scripts.Script.podcast?(script)
  defp lesson?(script), do: Moorland.Scripts.Script.lesson?(script)
  defp screenplay?(script), do: script.kind == "screenplay"
  defp sluglines?(script), do: Moorland.Scripts.Script.sluglines?(script)

  @panels [
    {"comments", "hero-chat-bubble-left", "Comments"},
    {"notes", "hero-clipboard-document-list", "Notes"},
    {"bin", "hero-archive-box", "Bin"},
    {"lookup", "hero-book-open", "Lookup"},
    {"history", "hero-clock", "History"},
    {"reports", "hero-chart-bar", "Reports"},
    {"breakdown", "hero-tag", "Breakdown"},
    {"share", "hero-user-plus", "Share"}
  ]

  # The side panels this document offers; only scene-based kinds break down.
  defp editor_panels(script) do
    Enum.reject(@panels, fn {panel, _, _} -> panel == "breakdown" and not sluglines?(script) end)
  end

  defp panel_icon(panel) do
    case List.keyfind(@panels, panel, 0) do
      {_, icon, _} -> icon
      nil -> "hero-squares-2x2"
    end
  end

  # 90 -> "1:30"
  defp clock(seconds) when is_integer(seconds),
    do:
      "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"

  defp stat_tiles(%{lesson: true} = stats) do
    [
      {clock(stats.seconds), "est. runtime"},
      {length(stats.segments), "parts"},
      {length(stats.characters), "voices"},
      {stats.words, "words"}
    ]
  end

  defp stat_tiles(%{podcast: true} = stats) do
    [
      {clock(stats.seconds), "est. runtime"},
      {length(stats.segments), "segments"},
      {length(stats.characters), "speakers"},
      {stats.words, "words"}
    ]
  end

  defp stat_tiles(%{comic: true} = stats) do
    [
      {stats.pages, "pages"},
      {stats.panels, "panels"},
      {stats.balloons, "balloons"},
      {stats.words, "words"}
    ]
  end

  defp stat_tiles(%{stage: true} = stats) do
    [
      {stats.pages, "pages"},
      {"#{stats.minutes} min", "est. running time"},
      {"#{stats.acts} / #{stats.scene_count}", "acts / scenes"},
      {stats.words, "words"}
    ]
  end

  defp stat_tiles(%{multicam: true} = stats) do
    [
      {stats.pages, "multi-cam pages"},
      {"#{stats.minutes} min", "est. runtime"},
      {stats.scene_count, "scenes"},
      {stats.words, "words"}
    ]
  end

  defp stat_tiles(%{prose: true} = stats) do
    [
      {stats.pages, "manuscript pages"},
      {"#{stats.minutes} min", "reading time"},
      {stats.chapters, "chapters"},
      {stats.words, "words"}
    ]
  end

  defp stat_tiles(stats) do
    [
      {stats.pages, "pages"},
      {"#{stats.minutes} min", "est. runtime"},
      {stats.scene_count, "scenes"},
      {stats.words, "words"}
    ]
  end

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

      <header class="editor-header flex h-12 shrink-0 items-center gap-2 border-b border-base-300 bg-base-100 px-3 sm:gap-3">
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
          class="w-56 min-w-16 shrink"
        >
          <input
            type="text"
            name="title"
            value={@script.title}
            phx-debounce="800"
            autocomplete="off"
            class="w-full truncate rounded border-0 bg-transparent px-1 py-0.5 text-sm font-medium focus:bg-base-200 focus:outline-none"
          />
        </form>
        <div :if={!Scripts.can_edit?(@role)} class="truncate text-sm font-medium">
          {@script.title}
        </div>

        <span class="hidden shrink-0 rounded-full bg-base-200 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-base-content/60 sm:inline">
          {role_label(@role)}
        </span>

        <div class="hidden sm:block"><.revision_chip set={shown_revision(assigns)} /></div>

        <span
          id="save-status"
          class="text-xs text-base-content/40"
          data-saved-text="Saved"
          data-saving-text="Saving…"
          data-offline-text="Offline — changes kept locally"
        ></span>

        <div class="ml-auto flex min-w-0 items-center gap-1.5 lg:shrink-0 xl:gap-3">
          <div class="dropdown dropdown-end">
            <div
              tabindex="0"
              role="button"
              class="flex cursor-pointer items-center gap-1.5 rounded-md px-2.5 py-1 text-xs font-medium text-base-content/60 hover:text-base-content"
              title="Export"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" />
              <span class="hidden 2xl:inline">Export</span>
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
              <li :if={!prose?(@script)}>
                <button phx-click="export" phx-value-format="fountain">Fountain (.fountain)</button>
              </li>
              <li :if={!prose?(@script)}>
                <button phx-click="export" phx-value-format="fdx">Final Draft (.fdx)</button>
              </li>
              <li :if={!prose?(@script)}>
                <button phx-click="export" phx-value-format="html">Web page (.html)</button>
              </li>
              <li><button phx-click="export" phx-value-format="markdown">Markdown (.md)</button></li>
              <li :if={prose?(@script)}>
                <a id="export-docx" href={~p"/scripts/#{@script.id}/export/docx"}>
                  Word manuscript (.docx)
                </a>
              </li>
              <li :if={prose?(@script)}>
                <a id="export-epub" href={~p"/scripts/#{@script.id}/export/epub"}>E-book (.epub)</a>
              </li>
              <li :if={sluglines?(@script)}>
                <button phx-click="export" phx-value-format="sides">Script sides (PDF)…</button>
              </li>
            </ul>
          </div>

          <div class="dropdown dropdown-end hidden sm:block">
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
                  :for={
                    {name, label} <- [{"default", "Classic"}, {"sepia", "Sepia"}, {"slate", "Slate"}]
                  }
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
                  :for={
                    {name, label} <- [{"default", "Courier"}, {"mono", "Modern"}, {"serif", "Book"}]
                  }
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

          <div class="hidden lg:block"><Layouts.theme_toggle /></div>

          <button
            id="pin-header"
            type="button"
            onclick="moorlandUI.togglePin()"
            class="hidden rounded p-1.5 text-base-content/40 hover:bg-base-200 lg:block"
            title="Pin the toolbar (unpinned, it slides away while you write)"
          >
            <.icon name="hero-map-pin" class="size-4" />
          </button>

          <button
            id="fullscreen-toggle"
            type="button"
            onclick="moorlandUI.toggleFullscreen()"
            class="hidden rounded p-1.5 text-base-content/40 hover:bg-base-200 lg:block"
            title="Browser full screen (Esc leaves it)"
          >
            <.icon name="hero-arrows-pointing-out" class="fs-enter size-4" />
            <.icon name="hero-arrows-pointing-in" class="fs-exit size-4" />
          </button>

          <button
            id="hide-header"
            type="button"
            onclick="moorlandUI.toggleHeader()"
            class="hidden rounded p-1.5 text-base-content/40 hover:bg-base-200 lg:block"
            title="Hide the toolbar — the small chevron at the top of the page brings it back"
          >
            <.icon name="hero-chevron-up" class="size-4" />
          </button>

          <div class="hidden -space-x-1.5 lg:flex" title={Enum.join(@presences, ", ")}>
            <span
              :for={email <- Enum.take(@presences, 5)}
              class="flex size-6 items-center justify-center rounded-full border-2 border-base-100 bg-neutral text-[10px] font-semibold text-neutral-content"
              title={email}
            >
              {initials(email)}
            </span>
          </div>

          <details
            id="panel-menu"
            class="dropdown dropdown-end sm:hidden"
            phx-click-away={JS.remove_attribute("open", to: "#panel-menu")}
          >
            <summary
              class={[
                "relative flex cursor-pointer list-none items-center gap-1 rounded-md px-2 py-1 text-xs font-medium transition [&::-webkit-details-marker]:hidden",
                if(@panel, do: "bg-base-200 text-base-content", else: "text-base-content/60")
              ]}
              title="Panels"
            >
              <.icon name={panel_icon(@panel)} class="size-4" />
              <.icon name="hero-chevron-down-mini" class="size-3 opacity-60" />
              <span
                :if={visible_comments(@comments, false) != [] or @suggestions != []}
                class="absolute right-0.5 top-0.5 size-1.5 rounded-full bg-neutral"
              />
            </summary>
            <ul class="dropdown-content menu z-50 mt-1 w-48 rounded-lg border border-base-300 bg-base-100 p-1 text-sm shadow-lg">
              <li :for={{panel, icon, label} <- editor_panels(@script)}>
                <button
                  type="button"
                  phx-click={
                    JS.push("toggle_panel", value: %{panel: panel})
                    |> JS.remove_attribute("open", to: "#panel-menu")
                  }
                  class={@panel == panel && "menu-active"}
                >
                  <.icon name={icon} class="size-4" />
                  {label}
                  <span
                    :if={panel == "comments" && visible_comments(@comments, false) != []}
                    class="ml-auto rounded-full bg-neutral px-1.5 text-[10px] text-neutral-content"
                  >
                    {length(visible_comments(@comments, false))}
                  </span>
                  <span
                    :if={panel == "history" && @suggestions != []}
                    class="ml-auto rounded-full bg-primary px-1.5 text-[10px] text-primary-content"
                  >
                    {length(@suggestions)}
                  </span>
                </button>
              </li>
            </ul>
          </details>

          <div
            id="panel-tabs"
            class="hidden min-w-16 items-center gap-0.5 overflow-x-auto rounded-lg bg-base-200 p-0.5 sm:flex lg:shrink-0"
          >
            <button
              :for={{panel, icon, label} <- editor_panels(@script)}
              phx-click="toggle_panel"
              phx-value-panel={panel}
              class={[
                "flex shrink-0 items-center gap-1.5 rounded-md px-2.5 py-1 text-xs font-medium transition",
                @panel == panel && "bg-base-100 shadow-sm",
                @panel != panel && "text-base-content/60 hover:text-base-content"
              ]}
              title={label}
            >
              <.icon name={icon} class="size-4" />
              <span class="hidden 2xl:inline">{label}</span>
              <span
                :if={panel == "comments" && visible_comments(@comments, false) != []}
                class="rounded-full bg-neutral px-1.5 text-[10px] text-neutral-content"
              >
                {length(visible_comments(@comments, false))}
              </span>
              <span
                :if={panel == "history" && @suggestions != []}
                class="rounded-full bg-primary px-1.5 text-[10px] text-primary-content"
                title="Suggested edits waiting"
              >
                {length(@suggestions)}
              </span>
            </button>
          </div>
        </div>
      </header>

      <.stages_strip :if={@script.stage} script={@script} lineage={@lineage} />

      <div class={["flex min-h-0 flex-1", @panel == "breakdown" && "bd-show"]}>
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
          data-kind={@script.kind}
          data-can-lock-pages={
            to_string(
              Scripts.can_edit?(@role) && is_nil(@script.origin_public_key) && screenplay?(@script)
            )
          }
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
              placeholder={
                if prose?(@script),
                  do:
                    "# Chapter One\n\nStart writing. Markdown works: # for chapters, ## for scenes, *italics*, and *** for a scene break.",
                  else:
                    "INT. COFFEE SHOP - DAY\n\nStart writing. Scene headings, character names and dialogue are formatted automatically in the preview."
              }
              class="editor-textarea"
            >{@script.content}</textarea>
            <div id="autocomplete-menu" class="autocomplete-menu" hidden></div>
            <button
              :if={Scripts.can_edit?(@role) && !prose?(@script)}
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
          <div
            id="preview-wrap"
            class="preview-pane relative hidden min-w-0 flex-1 overflow-y-auto md:block"
          >
            <div id="screenplay-preview" class="screenplay"></div>
            <div id="comment-bubble" class="comment-bubble" hidden>
              <button type="button" data-comment title="Comment on this selection">
                <.icon name="hero-chat-bubble-left" class="size-3.5" /> Comment
              </button>
              <button
                type="button"
                data-tag
                title="Tag this for the breakdown: a prop, costume, vehicle, effect…"
              >
                <.icon name="hero-tag" class="size-3.5" /> Tag
              </button>
              <button
                type="button"
                data-shot
                title="Plan a shot on this moment (it goes on the shot list)"
              >
                <.icon name="hero-video-camera" class="size-3.5" /> Shot
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
            notes={Enum.filter(@notes, &(&1.kind == @notes_kind))}
            kind={@notes_kind}
            counts={Enum.frequencies_by(@notes, & &1.kind)}
            characters={@characters}
            editing_sheet={@editing_sheet}
            prose={prose?(@script)}
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
          <div :if={@panel == "history"}>
            <.suggestions_section
              suggestions={@suggestions}
              open_id={@open_suggestion}
              content={@script.content}
              role={@role}
            />
            <.revision_section
              sets={@revision_sets}
              shown={shown_revision(assigns)}
              role={@role}
            />
            <.history_panel versions={@versions} role={@role} />
          </div>
          <.reports_panel
            :if={@panel == "reports"}
            stats={@stats}
            script={@script}
            role={@role}
            char_meta={@char_meta}
            sprint={@sprint}
          />
          <.prose_report :if={@panel == "reports" && @prose_report} report={@prose_report} />
          <.breakdown_panel
            :if={@panel == "breakdown"}
            script={@script}
            role={@role}
            user_id={@current_scope.user.id}
            draft={@tag_draft}
            scene={scene_for_line(@breakdown, (@tag_draft || @anchor || %{line: nil}).line)}
            unplaced={length(@breakdown.unplaced)}
          />
          <.share_panel
            :if={@panel == "share"}
            script={@script}
            collaborators={@collaborators}
            role={@role}
            peers={@peers}
            peer_shares={@peer_shares}
            peer_routes={@peer_routes}
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
              Line {@anchor.line + 1}<span :if={@anchor.text != ""}>: “{String.slice(
                @anchor.text,
                0,
                24
              )}”</span>
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
              <.assistant_badge :if={comment.from_assistant} />
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
            <.assistant_badge :if={reply.from_assistant} />
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
  attr :kind, :string, required: true
  attr :counts, :map, required: true
  attr :characters, :list, default: []
  attr :editing_sheet, :any, default: nil
  attr :prose, :boolean, default: false
  attr :role, :atom, required: true
  attr :current_user_id, :integer, required: true

  defp notes_panel(assigns) do
    ~H"""
    <div class="flex flex-col">
      <div class="flex items-center justify-between gap-2 border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold">Notes</h2>
        <div class="flex items-center gap-0.5 rounded-lg bg-base-200 p-0.5" role="tablist">
          <button
            :for={
              {kind, label} <- [
                {"note", "Notes"},
                {"sketch", "Sketches"},
                {"character", "Characters"}
              ]
            }
            id={"notes-tab-#{kind}"}
            type="button"
            role="tab"
            aria-selected={to_string(@kind == kind)}
            phx-click="notes_kind"
            phx-value-kind={kind}
            class={[
              "rounded-md px-2 py-0.5 text-[11px] font-medium transition",
              @kind == kind && "bg-base-100 shadow-sm",
              @kind != kind && "text-base-content/60 hover:text-base-content"
            ]}
          >
            {label}
            <span :if={@counts[kind]} class="ml-0.5 tabular-nums text-base-content/40">
              {@counts[kind]}
            </span>
          </button>
        </div>
      </div>

      <.characters_tab
        :if={@kind == "character"}
        rows={@characters}
        editing={@editing_sheet}
        role={@role}
        current_user_id={@current_user_id}
        prose={@prose}
      />

      <form
        :if={Scripts.can_comment?(@role) && @kind != "character"}
        id="add-note-form"
        phx-submit="add_note"
        class="border-b border-base-300 px-4 py-3"
      >
        <input type="hidden" name="kind" value={@kind} />
        <textarea
          name="body"
          rows={if @kind == "sketch", do: "4", else: "2"}
          required
          placeholder={
            if @kind == "sketch",
              do: "A premise, a character, a scrap of dialogue… The first line becomes its title.",
              else: "Story ideas, research, reminders…"
          }
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
              ]}></span>
            </label>
          </div>
          <button type="submit" class="btn btn-neutral btn-xs">
            {if @kind == "sketch", do: "Add sketch", else: "Add note"}
          </button>
        </div>
      </form>

      <div :if={@kind != "character"} class="space-y-3 p-4">
        <div
          :for={note <- @notes}
          class={["rounded-lg border p-3 shadow-sm", note_color_class(note.color)]}
        >
          <div class="flex items-start justify-between gap-2">
            <span class="text-[11px] font-semibold text-base-content/60">
              {author_label(note)}<.assistant_badge :if={note.from_assistant} />{if note.remote_author,
                do: " (via peer)"} · {time_ago(note.updated_at)}
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
          <button
            :if={note.kind == "sketch"}
            type="button"
            phx-click="script_from_sketch"
            phx-value-id={note.id}
            class="mt-2 flex items-center gap-1 text-[11px] font-medium text-base-content/60 transition hover:text-base-content"
            title="Open a new script with this sketch kept at the top"
          >
            <.icon name="hero-document-plus" class="size-3.5" /> Start a script from this
          </button>
        </div>

        <p :if={@notes == []} class="py-6 text-center text-sm text-base-content/40">
          {if @kind == "sketch",
            do: "No sketches yet. Keep ideas that aren't a script yet here.",
            else: "No notes yet."}
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

      <form
        id="lookup-form"
        phx-submit="lookup"
        class="flex gap-1.5 border-b border-base-300 px-4 py-3"
      >
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
          {cond do
            prose?(@script) ->
              "A manuscript page is about 250 words; reading time assumes 230 words a minute."

            podcast?(@script) or lesson?(@script) ->
              "Runtime is spoken words at 150 a minute, plus the written length of silent segments."

            @script.kind == "comic" ->
              "Pages are # sections, panels ## sections; balloons are numbered within each page."

            @script.kind == "stageplay" ->
              "Acts are # sections and scenes ## sections; a page plays about a minute."

            @script.kind == "multicam" ->
              "Multi-cam pages are double-spaced: about two to a screen minute."

            true ->
              "Estimates use the standard page ≈ one minute of screen time."
          end}
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
            :for={{value, label} <- stat_tiles(@stats)}
            class="rounded-lg border border-base-300 px-3 py-2.5"
          >
            <div class="text-lg font-semibold tabular-nums">{value}</div>
            <div class="text-[11px] text-base-content/50">{label}</div>
          </div>
        </div>

        <div :if={(Scripts.can_edit?(@role) or @script.goal_words) || @script.goal_pages} class="mt-5">
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
            {cond do
              podcast?(@script) -> "Speakers"
              lesson?(@script) -> "Voices"
              @script.kind == "comic" -> "Who speaks"
              true -> "Speaking parts"
            end}
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

        <div :if={@stats[:page_list] not in [nil, []]} id="comic-pages" class="mt-5">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Pages
          </h3>
          <table class="mt-2 w-full text-xs">
            <thead class="text-[10px] uppercase tracking-wide text-base-content/40">
              <tr>
                <th class="py-1 pr-2 text-left font-medium"></th>
                <th class="py-1 text-right font-medium">Panels</th>
                <th class="py-1 text-right font-medium">Balloons</th>
                <th class="py-1 text-right font-medium">Words</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-200">
              <tr :for={page <- @stats.page_list}>
                <td class="max-w-0 truncate py-1 pr-2">{page.title}</td>
                <td
                  class={["py-1 text-right tabular-nums", page.crowded && "text-warning"]}
                  title={page.crowded && "More than six panels: a crowded page"}
                >
                  {page.panels}
                </td>
                <td class="py-1 text-right tabular-nums">{page.balloons}</td>
                <td
                  class={["py-1 text-right tabular-nums", page.long_balloons > 0 && "text-warning"]}
                  title={
                    page.long_balloons > 0 &&
                      "#{page.long_balloons} #{if page.long_balloons == 1, do: "balloon runs", else: "balloons run"} over 25 words"
                  }
                >
                  {page.words}
                </td>
              </tr>
            </tbody>
          </table>
          <p class="mt-1 text-[11px] text-base-content/50">
            Amber marks a page over six panels, or one with a balloon over 25 words.
          </p>
        </div>

        <div :if={@stats[:segments] not in [nil, []]} id="podcast-segments" class="mt-5">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            {if @stats[:lesson], do: "Parts", else: "Segments"}
          </h3>
          <table class="mt-2 w-full text-xs">
            <tbody class="divide-y divide-base-200">
              <tr :for={seg <- @stats.segments}>
                <td class="py-1 pr-2">{seg.title}</td>
                <td
                  class={[
                    "py-1 text-right tabular-nums",
                    seg.target && seg.words > 0 && seg.seconds > seg.target && "text-warning"
                  ]}
                  title={seg.target && "Planned #{clock(seg.target)}"}
                >
                  {clock(seg.seconds)}<span
                    :if={seg.target && seg.words > 0}
                    class="text-base-content/40"
                  > / {clock(seg.target)}</span>
                </td>
              </tr>
            </tbody>
            <tfoot>
              <tr class="border-t border-base-300 font-semibold">
                <td class="py-1 pr-2">Total</td>
                <td class="py-1 text-right tabular-nums">{clock(@stats.seconds)}</td>
              </tr>
            </tfoot>
          </table>
          <p class="mt-1 text-[11px] text-base-content/50">
            Speech at 150 words a minute. Give a silent segment its length with a line like <code>= 1:00</code>.
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

        <p
          :if={@stats.scene_count == 0 and @stats.words == 0}
          class="py-6 text-center text-sm text-base-content/40"
        >
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
  attr :peer_routes, :map, required: true

  defp share_panel(assigns) do
    assigns = assign(assigns, :studios, Enum.filter(assigns.peers, & &1.studio))

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
          <form
            :if={@role == :owner}
            id={"role-form-#{collab.id}"}
            phx-change="update_role"
            class="shrink-0"
          >
            <input type="hidden" name="collab_id" value={collab.id} />
            <select name="role" class="select select-bordered select-xs">
              <option
                :for={r <- Moorland.Scripts.Collaborator.roles()}
                value={r}
                selected={collab.role == r}
              >
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
          {if @studios == [],
            do: "Shared peers mirror this script on their machine and sync directly with yours.",
            else:
              "Shared peers mirror this script on their machine and sync with yours directly, or through a studio that stands in while you're away."}
        </p>
        <div class="mt-2 space-y-2">
          <form
            :for={peer <- @peers}
            id={"peer-share-#{peer.id}"}
            phx-change="set_peer_share"
            class="space-y-1"
          >
            <input type="hidden" name="peer_id" value={peer.id} />
            <div class="flex items-center justify-between gap-2">
              <span class="min-w-0 flex-1 truncate text-sm">{peer.name}</span>
              <select name="role" class="select select-bordered select-xs w-28 shrink-0">
                <option value="" selected={!Map.has_key?(@peer_shares, peer.id)}>Not shared</option>
                <option value="editor" selected={@peer_shares[peer.id] == "editor"}>Editor</option>
                <option value="commenter" selected={@peer_shares[peer.id] == "commenter"}>
                  Commenter
                </option>
                <option value="viewer" selected={@peer_shares[peer.id] == "viewer"}>Viewer</option>
              </select>
            </div>
            <% studios = Enum.reject(@studios, &(&1.id == peer.id)) %>
            <div
              :if={Map.has_key?(@peer_shares, peer.id) and studios != []}
              class="flex items-center justify-end gap-1.5 text-[11px] text-base-content/50"
            >
              <.icon name="hero-arrows-right-left" class="size-3" />
              <select
                name="studio_peer_id"
                class="select select-ghost select-xs h-6 min-h-6 w-auto max-w-48 text-[11px]"
                aria-label={"How #{peer.name} receives it"}
                title="Through a studio, they can keep syncing while this machine is off"
              >
                <option value="" selected={is_nil(@peer_routes[peer.id])}>Directly</option>
                <option
                  :for={studio <- studios}
                  value={studio.id}
                  selected={@peer_routes[peer.id] == studio.id}
                >
                  Through {studio.name}
                </option>
              </select>
            </div>
          </form>
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
    <div
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-6"
      phx-click="close_title_form"
    >
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
          <label
            :for={
              {key, label, placeholder} <- [
                {"title", "Title", "The name of the script"},
                {"credit", "Credit", "Written by"},
                {"author", "Author", "Your name"},
                {"source", "Based on", "Optional source material"},
                {"draft_date", "Draft date", "Optional"},
                {"copyright", "Copyright", "Optional"}
              ]
            }
            class="block"
          >
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
    <div
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-6"
      phx-click="close_diff"
    >
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
              <span class="text-error">removed</span>
              lines were in the version; <span class="text-success">added</span>
              lines are in the current draft.
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
          >
            <span class="select-none pr-2 text-base-content/30">{case op do
              :del -> "-"
              :ins -> "+"
              :eq -> " "
            end}</span>{if line ==
                                                                                                                                                                      "",
                                                                                                                                                                    do:
                                                                                                                                                                      " ",
                                                                                                                                                                    else:
                                                                                                                                                                      line}
          </div>
        </div>
      </div>
    </div>
    """
  end
end
