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
end
