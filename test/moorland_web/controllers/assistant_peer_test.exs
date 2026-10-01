defmodule MoorlandWeb.AssistantPeerTest do
  # Plays an AI assistant connected as a peer, over the real sealed wire:
  # a commenter share lets it read, comment, note and tag, never write.
  use MoorlandWeb.ConnCase

  import Moorland.AccountsFixtures
  import Swoosh.TestAssertions
  import Phoenix.LiveViewTest

  alias Moorland.Accounts.Scope
  alias Moorland.Peers
  alias Moorland.Peers.{Crypto, Envelope}
  alias Moorland.Scripts

  @skew 300

  setup %{conn: conn} do
    writer = user_fixture()
    scope = Scope.for_user(writer)

    {:ok, script} =
      Scripts.create_script(scope, %{
        title: "Lighthouse",
        content: "INT. LAMP ROOM - NIGHT\n\nThe lamp turns."
      })

    keys = Crypto.generate_keypair()

    {:ok, peer} =
      Peers.add_peer(scope, Crypto.format_code(keys.public, "10.0.0.7", 4000), "Script assistant")

    {:ok, _} = Peers.set_assistant(scope, peer.id, true)
    :ok = Scripts.set_peer_share(scope, script, peer.id, "commenter")
    flush_emails()

    %{
      conn: conn,
      scope: scope,
      writer: writer,
      script: script,
      peer: peer,
      remote: %{public_key: keys.public, private_key: keys.private}
    }
  end

  defp call(conn, remote, op, args) do
    hello = get(conn, "/peer/api/hello") |> json_response(200)
    {:ok, kx} = Envelope.verify_hello(hello, Peers.identity().public_key, now(), @skew)
    request = %{op: op, args: args, ts: now()}
    {envelope, session} = Envelope.seal(Jason.encode!(request), remote, kx)

    resp =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/peer/api/envelope", Jason.encode!(envelope))
      |> json_response(200)

    {:ok, plaintext} = Envelope.open_reply(session, resp["box"])
    %{"status" => status, "body" => body} = Jason.decode!(plaintext)
    {status, body}
  end

  defp now, do: System.system_time(:second)

  # Account fixtures send a confirmation email; start each test with none.
  defp flush_emails do
    receive do
      {:email, _} -> flush_emails()
    after
      0 -> :ok
    end
  end

  test "reads the script and adds badged comments, notes and tags", ctx do
    %{conn: conn, remote: remote, script: script, writer: writer} = ctx
    handle = writer.email |> String.split("@") |> hd()

    assert {200, %{"scripts" => [%{"role" => "commenter"}]}} = call(conn, remote, "shared", %{})
    assert {200, %{"content" => content}} = call(conn, remote, "fetch", %{id: script.id})
    assert content =~ "The lamp turns."

    activity = %{
      comments: [
        %{
          uid: "ai-1",
          body: "@#{handle} the lamp turned clockwise in scene 1.",
          line_no: 2,
          anchor_text: "The lamp turns.",
          author: "assistant"
        }
      ],
      notes: [
        %{uid: "ai-2", body: "Continuity: lamp direction", color: "blue", author: "assistant"}
      ],
      tags: [
        %{
          uid: "ai-3",
          category: "props",
          name: "Lamp",
          anchor_text: "lamp",
          line_no: 2,
          author: "assistant"
        }
      ],
      versions: [%{uid: "ai-4", kind: "manual", message: "sneaky", content: "rewritten"}],
      schedule: [%{uid: "ai-5", kind: "day"}]
    }

    assert {200, %{"ok" => true}} =
             call(conn, remote, "activity_push", %{id: script.id, activity: activity})

    assert [%{from_assistant: true, remote_author: "assistant", line_no: 2}] =
             Scripts.list_comments(script)

    assert [%{from_assistant: true}] = Scripts.list_notes(script)
    assert [%{name: "Lamp"}] = Scripts.list_breakdown_tags(script)
    # Snapshots and the board are an editor's business.
    refute Enum.any?(Scripts.list_versions(script), &(&1.uid == "ai-4"))
    assert Scripts.list_schedule_items(script) == []

    # The mention notifies in the app, but sends no email.
    assert Scripts.unread_notifications(Scope.for_user(writer)) == %{script.id => 1}
    refute_email_sent()
  end

  test "can never change the text", %{conn: conn, remote: remote, script: script} do
    assert {403, %{"error" => "read only"}} =
             call(conn, remote, "save", %{id: script.id, content: "gone", base_version: 0})

    assert Scripts.get_script!(ctx_scope(script), script.id) |> elem(0) |> Map.get(:content) =~
             "The lamp turns."
  end

  test "a human's mention still sends email", %{
    conn: conn,
    scope: scope,
    peer: peer,
    remote: remote,
    script: script,
    writer: writer
  } do
    {:ok, _} = Peers.set_assistant(scope, peer.id, false)
    handle = writer.email |> String.split("@") |> hd()
    activity = %{comments: [%{uid: "h-1", body: "@#{handle} look", author: "casey"}]}

    assert {200, _} = call(conn, remote, "activity_push", %{id: script.id, activity: activity})
    assert [%{from_assistant: false}] = Scripts.list_comments(script)
    assert_email_sent(subject: ~s(You were mentioned in "Lighthouse"))
  end

  test "the badge travels on to other mirrors", %{conn: conn, remote: remote, script: script} do
    activity = %{comments: [%{uid: "ai-9", body: "Check the tide.", author: "assistant"}]}
    {200, _} = call(conn, remote, "activity_push", %{id: script.id, activity: activity})

    assert {200, %{"comments" => [%{"assistant" => true}]}} =
             call(conn, remote, "activity", %{id: script.id, after: 0})
  end

  test "the editor badges assistant comments", %{
    conn: conn,
    writer: writer,
    remote: remote,
    script: script
  } do
    activity = %{comments: [%{uid: "ai-10", body: "Check the tide.", author: "assistant"}]}
    {200, _} = call(conn, remote, "activity_push", %{id: script.id, activity: activity})

    {:ok, lv, _html} =
      build_conn() |> log_in_user(writer) |> live(~p"/scripts/#{script.id}")

    lv |> element("button[phx-value-panel=comments]") |> render_click()
    assert render(lv) =~ ~s(title="Written by an AI assistant connected as a peer")
  end

  defp ctx_scope(script) do
    script = Moorland.Repo.preload(script, :owner)
    Scope.for_user(script.owner)
  end

  describe "suggested edits" do
    defp suggest(conn, remote, script, uid, content, base, message \\ "Tighten the opening") do
      call(conn, remote, "activity_push", %{
        id: script.id,
        activity: %{
          suggestions: [
            %{
              uid: uid,
              content: content,
              base_version: base,
              message: message,
              author: "assistant"
            }
          ]
        }
      })
    end

    test "an assistant suggests; an editor applies it, keeping edits made since", ctx do
      %{conn: conn, remote: remote, script: script, scope: scope} = ctx
      base = script.content_version

      proposed = String.replace(script.content, "The lamp turns.", "The great lamp turns.")
      assert {200, %{"ok" => true}} = suggest(conn, remote, script, "s-1", proposed, base)

      assert [%{from_assistant: true, message: "Tighten the opening", status: "open"} = s] =
               Scripts.list_open_suggestions(script)

      # Meanwhile the writer adds a line at the end.
      {:ok, script} =
        Scripts.save_content(scope, script, script.content <> "\n\nIt never stops.", base)

      assert {:ok, saved} = Scripts.apply_suggestion(scope, script, s.id)
      assert saved.content =~ "The great lamp turns." and saved.content =~ "It never stops."
      assert Scripts.list_open_suggestions(script) == []
      assert {:error, :not_found} = Scripts.apply_suggestion(scope, saved, s.id)
    end

    test "dismissing, and who may decide", ctx do
      %{conn: conn, remote: remote, script: script, scope: scope} = ctx
      {200, _} = suggest(conn, remote, script, "s-2", "Something else", script.content_version)
      [s] = Scripts.list_open_suggestions(script)

      commenter = user_fixture()
      {:ok, _} = Scripts.add_collaborator(scope, script, commenter.email, "commenter")

      assert {:error, :not_allowed} =
               Scripts.apply_suggestion(Scope.for_user(commenter), script, s.id)

      assert {:error, :not_allowed} =
               Scripts.dismiss_suggestion(Scope.for_user(commenter), script, s.id)

      assert :ok = Scripts.dismiss_suggestion(scope, script, s.id)
      assert Scripts.list_open_suggestions(script) == []

      assert Scripts.get_script!(scope, script.id) |> elem(0) |> Map.get(:content) =~
               "The lamp turns."
    end

    test "a peer may have twenty open at most, and viewers none", ctx do
      %{conn: conn, remote: remote, script: script, scope: scope, peer: peer} = ctx
      for n <- 1..25, do: suggest(conn, remote, script, "bulk-#{n}", "x#{n}", 0)
      assert length(Scripts.list_open_suggestions(script)) == 20

      :ok = Scripts.set_peer_share(scope, script, peer.id, "viewer")
      assert {403, _} = suggest(conn, remote, script, "late", "y", 0)
    end

    test "the History panel shows the suggestion and applies it", ctx do
      %{conn: conn, remote: remote, script: script, writer: writer} = ctx
      proposed = String.replace(script.content, "The lamp turns.", "The great lamp turns.")
      {200, _} = suggest(conn, remote, script, "s-3", proposed, script.content_version)
      [s] = Scripts.list_open_suggestions(script)

      {:ok, lv, _html} = build_conn() |> log_in_user(writer) |> live(~p"/scripts/#{script.id}")
      assert has_element?(lv, "button[phx-value-panel=history]", "1")
      lv |> element("button[phx-value-panel=history]") |> render_click()
      assert has_element?(lv, "#suggestion-#{s.id}", "Tighten the opening")

      lv |> element("#suggestion-#{s.id} button", "Show changes") |> render_click()
      assert has_element?(lv, "#suggestion-#{s.id} .text-success", "The great lamp turns.")

      lv |> element("#suggestion-#{s.id} button", "Apply") |> render_click()
      assert_push_event(lv, "remote_content", %{content: content})
      assert content =~ "The great lamp turns."
      refute has_element?(lv, "#suggestion-#{s.id}")
    end
  end
end
