defmodule MoorlandWeb.ShotsLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts

  @content "INT. HALL - DAY\n\nThe lamp turns slowly.\n\nEXT. CLIFF - NIGHT\n\nWaves break."

  setup %{conn: conn} do
    user = user_fixture()
    scope = Scope.for_user(user)
    {:ok, script} = Scripts.create_script(scope, %{title: "Lighthouse"})
    {:ok, script} = Scripts.save_content(scope, script, @content)
    %{conn: log_in_user(conn, user), scope: scope, script: script}
  end

  defp shot(scope, script, anchor, line, attrs \\ %{}) do
    {:ok, shot} =
      Scripts.create_shot(scope, script, Map.merge(%{anchor_text: anchor, line_no: line}, attrs))

    shot
  end

  test "shots are validated and anchored like tags", %{scope: scope, script: script} do
    s = shot(scope, script, "lamp turns slowly. EXT", 2, %{size: "CU", description: " The lamp "})
    assert s.anchor_text == "lamp turns slowly." and s.description == "The lamp"

    assert {:error, cs} = Scripts.create_shot(scope, script, %{line_no: 2, size: "HUGE"})
    assert "is invalid" in Moorland.DataCase.errors_on(cs).size
  end

  test "commenters add shots; only author or editor change them", %{scope: scope, script: script} do
    commenter = user_fixture()
    {:ok, _} = Scripts.add_collaborator(scope, script, commenter.email, "commenter")
    other = Scope.for_user(commenter)

    mine = shot(other, script, "lamp", 2)
    theirs = shot(scope, script, "Waves", 6)

    assert {:error, :not_allowed} =
             Scripts.update_shot(other, script, theirs.id, %{"size" => "WS"})

    assert {:error, :not_allowed} = Scripts.delete_shot(other, script, theirs.id)
    assert {:ok, %{size: "WS"}} = Scripts.update_shot(other, script, mine.id, %{"size" => "WS"})

    assert {:ok, %{lens: "35mm"}} =
             Scripts.update_shot(scope, script, mine.id, %{"lens" => "35mm"})

    assert {:error, :not_found} = Scripts.update_shot(scope, script, "nope", %{})

    viewer = user_fixture()
    {:ok, _} = Scripts.add_collaborator(scope, script, viewer.email, "viewer")

    assert {:error, :not_allowed} =
             Scripts.create_shot(Scope.for_user(viewer), script, %{line_no: 2})
  end

  test "the shot list page adds, edits, reorders and deletes", %{
    conn: conn,
    scope: scope,
    script: script
  } do
    first = shot(scope, script, "lamp", 2, %{description: "Wide on the lamp"})
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/shots")

    assert has_element?(lv, "#shot-#{first.id}", "1A")

    lv |> form("#add-shot-1", %{"size" => "CU", "description" => "Lens flare"}) |> render_submit()
    [_, second] = Scripts.list_shots(script)
    assert has_element?(lv, "#shot-#{second.id}", "1B")

    lv |> element("#shot-#{second.id} button[title='Move up']") |> render_click()
    assert has_element?(lv, "#shot-#{second.id}", "1A")
    assert has_element?(lv, "#shot-#{first.id}", "1B")

    lv |> form("#shot-form-#{first.id}", %{"size" => "ECU", "lens" => "85mm"}) |> render_change()

    assert %{size: "ECU", lens: "85mm"} =
             Enum.find(Scripts.list_shots(script), &(&1.id == first.id))

    lv |> element("#shot-#{first.id} button[title='Delete this shot']") |> render_click()
    refute has_element?(lv, "#shot-#{first.id}")
  end

  test "viewers read the shot list but cannot change it", %{scope: scope, script: script} do
    shot(scope, script, "lamp", 2, %{size: "CU", description: "On the lamp"})
    viewer = user_fixture()
    {:ok, _} = Scripts.add_collaborator(scope, script, viewer.email, "viewer")

    {:ok, lv, _html} =
      build_conn() |> log_in_user(viewer) |> live(~p"/scripts/#{script.id}/shots")

    assert has_element?(lv, "#shots-scene-1", "On the lamp")
    refute has_element?(lv, "form[phx-change=update_shot]")
    refute has_element?(lv, "#add-shot-1")
  end

  test "Shot in the preview bubble plans a shot on those words", %{conn: conn, script: script} do
    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}")
    render_hook(lv, "shot_selection", %{"line" => 6, "text" => "Waves break."})

    assert [%{anchor_text: "Waves break.", description: "Waves break.", line_no: 6}] =
             Scripts.list_shots(script)
  end

  describe "storyboard frames" do
    # A 1x1 PNG.
    @png Base.decode64!(
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
         )

    test "upload, serve, replace and remove a frame", %{conn: conn, scope: scope, script: script} do
      s = shot(scope, script, "lamp", 2)
      {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}/shots")

      lv |> element("#shot-#{s.id} button", "Frame") |> render_click()

      frame =
        file_input(lv, "#shot-image-form-#{s.id}", :image, [
          %{name: "frame.png", content: @png, type: "image/png"}
        ])

      render_upload(frame, "frame.png")

      [%{image: name}] = Scripts.list_shots(script)
      assert name =~ ~r/^shot-.+\.png$/
      assert has_element?(lv, "#shot-#{s.id} img")

      resp = get(conn, ~p"/scripts/#{script.id}/shots/#{s.id}/image")
      assert response(resp, 200) == @png
      assert response_content_type(resp, :png) =~ "image/png"

      path = Path.join(Moorland.Storage.media_dir(script.id), name)
      assert File.exists?(path)

      {:ok, _} = Scripts.remove_shot_image(scope, script, s.id)
      refute File.exists?(path)
      assert conn |> get(~p"/scripts/#{script.id}/shots/#{s.id}/image") |> response(404)
    end

    test "only images, only from those allowed, only to those allowed", %{
      scope: scope,
      script: script
    } do
      s = shot(scope, script, "lamp", 2)
      tmp = Path.join(System.tmp_dir!(), "frame-#{System.unique_integer([:positive])}.png")
      File.write!(tmp, @png)

      assert {:error, :unsupported} = Scripts.attach_shot_image(scope, script, s.id, tmp, ".exe")

      viewer = user_fixture()
      {:ok, _} = Scripts.add_collaborator(scope, script, viewer.email, "viewer")

      assert {:error, _} =
               Scripts.attach_shot_image(Scope.for_user(viewer), script, s.id, tmp, ".png")

      {:ok, _} = Scripts.attach_shot_image(scope, script, s.id, tmp, ".PNG")
      stranger = build_conn() |> log_in_user(user_fixture())

      assert_error_sent 404, fn ->
        get(stranger, ~p"/scripts/#{script.id}/shots/#{s.id}/image")
      end

      # Deleting the shot, then the script, clears its media.
      [%{image: name}] = Scripts.list_shots(script)
      :ok = Scripts.delete_shot(scope, script, s.id)
      refute File.exists?(Path.join(Moorland.Storage.media_dir(script.id), name))
      {:ok, _} = Scripts.delete_script(scope, script)
      refute File.exists?(Moorland.Storage.media_dir(script.id))
    end
  end
end
