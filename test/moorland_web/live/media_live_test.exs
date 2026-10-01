defmodule MoorlandWeb.MediaLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts

  setup %{conn: conn} do
    user = user_fixture()
    scope = Scope.for_user(user)
    {:ok, script} = Scripts.create_script(scope, %{title: "Harbour", content: "INT. HALL - DAY"})
    %{conn: log_in_user(conn, user), scope: scope, script: script}
  end

  defp upload(lv, name, bytes, type) do
    lv
    |> file_input("#media-upload", :files, [
      %{name: name, content: bytes, type: type, size: byte_size(bytes)}
    ])
    |> render_upload(name)
  end

  test "drops files in, pins them to a board, edits and removes them", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/scripts/#{ctx.script.id}/media")
    assert has_element?(lv, "#media-empty")

    upload(lv, "pier.jpg", "JPEGDATA", "image/jpeg")
    [item] = Scripts.list_media(ctx.script)
    assert has_element?(lv, "#media-#{item.id} img")
    refute has_element?(lv, "#media-empty")

    # A new board is where the next uploads land.
    lv |> form("#new-board-form", %{name: "Harbour at night"}) |> render_submit()
    assert_patch(lv, ~p"/scripts/#{ctx.script.id}/media?#{[board: "Harbour at night"]}")
    assert has_element?(lv, "#media-empty")

    upload(lv, "lookbook.pdf", "%PDF-1.4", "application/pdf")

    assert [%{board: "Harbour at night"}] =
             Enum.filter(Scripts.list_media(ctx.script), &(&1.board != ""))

    # Back on Everything, the first file can be pinned with one click.
    {:ok, lv, _html} = live(ctx.conn, ~p"/scripts/#{ctx.script.id}/media")

    lv
    |> element("#media-#{item.id} button[phx-value-board='Harbour at night']")
    |> render_click()

    assert Scripts.list_media(ctx.script) |> Enum.all?(&(&1.board == "Harbour at night"))

    lv |> element("#media-#{item.id} button[phx-click=edit]") |> render_click()

    lv
    |> form("#media-form-#{item.id}", %{title: "The pier", caption: "Sodium light"})
    |> render_change()

    assert %{title: "The pier", caption: "Sodium light"} =
             Enum.find(Scripts.list_media(ctx.script), &(&1.id == item.id))

    lv |> element("#media-form-#{item.id} button[phx-click=delete_item]") |> render_click()
    refute has_element?(lv, "#media-#{item.id}")
  end

  test "serves the file to people who can open the script, and nobody else", ctx do
    path = Path.join(System.tmp_dir!(), "ref-#{System.unique_integer([:positive])}")
    File.write!(path, "PNGDATA")
    {:ok, item} = Scripts.add_media(ctx.scope, ctx.script, path, "ref.png")

    conn = get(ctx.conn, ~p"/scripts/#{ctx.script.id}/media/#{item.id}/file")
    assert response(conn, 200) == "PNGDATA"
    assert get_resp_header(conn, "content-type") == ["image/png"]

    conn = get(ctx.conn, ~p"/scripts/#{ctx.script.id}/media/#{item.id}/file?download=1")
    assert [~s(attachment; filename="ref.png")] = get_resp_header(conn, "content-disposition")

    stranger = build_conn() |> log_in_user(user_fixture())

    assert_error_sent 404, fn ->
      get(stranger, ~p"/scripts/#{ctx.script.id}/media/#{item.id}/file")
    end
  end
end
