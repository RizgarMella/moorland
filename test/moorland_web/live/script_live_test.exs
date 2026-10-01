defmodule MoorlandWeb.ScriptLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user, scope: Scope.for_user(user)}
  end

  test "dashboard lists and creates scripts", %{conn: conn, scope: scope} do
    {:ok, _} = Scripts.create_script(scope, %{title: "Cold Open"})

    {:ok, lv, html} = live(conn, ~p"/scripts")
    assert html =~ "Cold Open"

    lv
    |> form("form[phx-submit=create]", %{"title" => "Act Two"})
    |> render_submit()

    assert_redirect(lv)
  end

  test "header nav marks the section a page belongs to", %{conn: conn, scope: scope} do
    {:ok, script} = Scripts.create_script(scope, %{title: "Cold Open"})

    for {path, current} <- [
          {~p"/scripts", "/scripts"},
          {~p"/scripts/#{script.id}/breakdown", "/scripts"},
          {~p"/contacts", "/contacts"},
          {~p"/peers", "/peers"}
        ] do
      {:ok, lv, _html} = live(conn, path)
      assert has_element?(lv, ~s(#primary-nav a[href="#{current}"][aria-current="page"]))
      assert lv |> element("#primary-nav a[aria-current]") |> render() =~ current
    end
  end

  test "production pages share tabs that mark the current document", %{
    conn: conn,
    scope: scope
  } do
    {:ok, script} = Scripts.create_script(scope, %{title: "Cold Open"})

    for {path, tab} <- [
          {~p"/scripts/#{script.id}/breakdown", "#open-breakdown"},
          {~p"/scripts/#{script.id}/shots", "#open-shots"},
          {~p"/scripts/#{script.id}/schedule", "#open-schedule"},
          {~p"/scripts/#{script.id}/schedule/day/1", "#open-schedule"},
          {~p"/scripts/#{script.id}/production", "#open-production"},
          {~p"/scripts/#{script.id}/media", "#open-media"}
        ] do
      {:ok, lv, _html} = live(conn, path)
      assert has_element?(lv, ~s(#back-to-script[href="/scripts/#{script.id}"]))
      assert has_element?(lv, "#production-tabs #{tab}[aria-current=page]")
      assert lv |> element("#production-tabs a[aria-current]") |> has_element?()
    end
  end

  test "phones get every editor panel from one menu", %{conn: conn, scope: scope} do
    {:ok, script} = Scripts.create_script(scope, %{title: "Cold Open"})
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}")

    assert has_element?(lv, "#panel-menu summary")
    assert lv |> element("#panel-menu li:nth-child(5) button") |> render_click() =~ "History"
    assert has_element?(lv, "#panel-menu li:nth-child(5) button.menu-active")
  end

  test "editor renders and saves content", %{conn: conn, scope: scope} do
    {:ok, script} = Scripts.create_script(scope, %{title: "Cold Open"})

    {:ok, lv, html} = live(conn, ~p"/scripts/#{script.id}")
    assert html =~ "Cold Open"
    assert html =~ "screenplay-input"

    render_hook(lv, "autosave", %{"content" => "INT. LAB - DAY\n\nA quiet hum."})
    {reloaded, :owner} = Scripts.get_script!(scope, script.id)
    assert reloaded.content =~ "INT. LAB - DAY"
  end

  test "editor panels open and accept input", %{conn: conn, scope: scope} do
    {:ok, script} = Scripts.create_script(scope, %{title: "Cold Open"})
    {:ok, lv, _} = live(conn, ~p"/scripts/#{script.id}")

    # Comments
    lv |> element("button[phx-value-panel=comments]") |> render_click()
    lv |> form("form[phx-submit=add_comment]", %{"body" => "Trim this?"}) |> render_submit()
    assert render(lv) =~ "Trim this?"

    # Notes
    lv |> element("button[phx-value-panel=notes]") |> render_click()

    lv
    |> form("form[phx-submit=add_note]", %{"body" => "Check era slang", "color" => "blue"})
    |> render_submit()

    assert render(lv) =~ "Check era slang"

    # History: snapshot then diff
    render_hook(lv, "autosave", %{"content" => "INT. LAB - DAY"})
    lv |> element("button[phx-value-panel=history]") |> render_click()
    lv |> form("form[phx-submit=snapshot]", %{"message" => "First pass"}) |> render_submit()
    assert render(lv) =~ "First pass"

    # Share panel renders the owner
    lv |> element("button[phx-value-panel=share]") |> render_click()
    assert render(lv) =~ "Sharing"
  end

  test "highlighting preview text opens comments with an anchor", %{conn: conn, scope: scope} do
    {:ok, script} = Scripts.create_script(scope, %{title: "Cold Open"})
    {:ok, lv, _} = live(conn, ~p"/scripts/#{script.id}")

    render_hook(lv, "comment_on_selection", %{"line" => 4, "text" => "Hey guys!"})
    html = render(lv)
    assert html =~ "Line 5"
    assert html =~ "Hey guys!"

    lv
    |> form("#add-comment-form", %{"body" => "Love this bit", "anchored" => "true"})
    |> render_submit()

    [comment] = Scripts.list_comments(script)
    assert comment.line_no == 4
    assert comment.anchor_text == "Hey guys!"
  end

  test "export and scene nav events round-trip to the client", %{conn: conn, scope: scope} do
    {:ok, script} = Scripts.create_script(scope, %{title: "Cold Open"})
    {:ok, lv, html} = live(conn, ~p"/scripts/#{script.id}")
    assert html =~ "scene-nav"
    assert html =~ "print-root"

    lv |> element("button[phx-click=toggle_nav]") |> render_click()
    assert_push_event(lv, "scene_nav", %{open: true})

    lv |> element("button[phx-value-format=fdx]") |> render_click()
    assert_push_event(lv, "export", %{format: "fdx"})

    lv |> element("button[phx-value-watermark=DRAFT]") |> render_click()
    assert_push_event(lv, "export", %{format: "pdf", watermark: "DRAFT"})
  end

  test "importing a script creates it and navigates", %{conn: conn, scope: scope} do
    {:ok, lv, _} = live(conn, ~p"/scripts")

    render_hook(lv, "import_script", %{
      "title" => "Imported Draft",
      "content" => "INT. LAB - DAY\n\nHello."
    })

    assert_redirect(lv)
    assert [%{title: "Imported Draft"} = script] = Scripts.list_scripts(scope)
    assert script.content =~ "INT. LAB - DAY"
  end

  test "viewer cannot edit", %{conn: _conn, scope: owner_scope} do
    {:ok, script} = Scripts.create_script(owner_scope, %{title: "Locked"})
    viewer = user_fixture()
    {:ok, _} = Scripts.add_collaborator(owner_scope, script, viewer.email, "viewer")

    conn = Phoenix.ConnTest.build_conn() |> log_in_user(viewer)
    {:ok, lv, html} = live(conn, ~p"/scripts/#{script.id}")
    assert html =~ "readonly"

    render_hook(lv, "autosave", %{"content" => "HACKED"})
    {reloaded, _} = Scripts.get_script!(owner_scope, script.id)
    refute reloaded.content =~ "HACKED"
  end

  test "strangers get a 404", %{scope: owner_scope} do
    {:ok, script} = Scripts.create_script(owner_scope, %{title: "Private"})
    stranger = user_fixture()
    conn = Phoenix.ConnTest.build_conn() |> log_in_user(stranger)

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/scripts/#{script.id}")
    end
  end

  test "the Peers page marks a peer as an assistant", %{conn: conn, scope: scope} do
    %{public: pub} = Moorland.Peers.Crypto.generate_keypair()

    {:ok, peer} =
      Moorland.Peers.add_peer(
        scope,
        Moorland.Peers.Crypto.format_code(pub, "10.0.0.5", 4000),
        "Bot"
      )

    {:ok, lv, _html} = live(conn, ~p"/peers")
    lv |> element("#assistant-#{peer.id}") |> render_click()
    assert Moorland.Peers.get_peer!(peer.id).assistant
    lv |> element("#assistant-#{peer.id}") |> render_click()
    refute Moorland.Peers.get_peer!(peer.id).assistant
  end

  test "importing a screenplay PDF melts it into a new script", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/scripts")

    pdf =
      file_input(lv, "#pdf-import-form", :pdf, [
        %{
          name: "lamp_draft3_FINAL.pdf",
          content: File.read!("test/fixtures/screenplay.pdf"),
          type: "application/pdf"
        }
      ])

    # The upload ends in navigation to the new script.
    assert {:error, {:live_redirect, %{to: path}}} = render_upload(pdf, "lamp_draft3_FINAL.pdf")

    [script] = Scripts.list_scripts(scope)
    assert path == "/scripts/#{script.id}"
    assert script.title == "The Lamp"
    assert script.content =~ "INT. LIGHTHOUSE - NIGHT"
  end

  test "a PDF without text explains itself", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/scripts")

    pdf =
      file_input(lv, "#pdf-import-form", :pdf, [
        %{name: "scan.pdf", content: "not really a pdf", type: "application/pdf"}
      ])

    render_upload(pdf, "scan.pdf")
    assert render(lv) =~ "isn&#39;t a PDF"
  end
end
