defmodule MoorlandWeb.UpdateInstallLiveTest do
  # Pretends to be a packaged build (environment variable, app config): not async.
  use MoorlandWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Peers.Crypto
  alias Moorland.Updates
  alias Moorland.Updates.Installer

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{conn: conn, tmp_dir: dir} do
    %{public: public, private: private} = Crypto.generate_keypair()
    exe = Path.join(dir, "moorland")
    File.write!(exe, "running build")
    build = Path.join(dir, "release_build")
    File.write!(build, "new build")
    File.write!(build <> ".sig", Installer.sign(build, Crypto.encode_key(private)))

    System.put_env("__BURRITO_BIN_PATH", exe)
    Application.put_env(:moorland, :release_public_key, Crypto.encode_key(public))
    Application.put_env(:moorland, :update_downloader, fn url, path -> File.cp(url, path) end)

    on_exit(fn ->
      System.delete_env("__BURRITO_BIN_PATH")
      Application.put_env(:moorland, :release_public_key, nil)
      Application.delete_env(:moorland, :update_downloader)
    end)

    name = Installer.asset_name(Installer.platform())

    release = %{
      tag: "v99.0.0",
      name: "v99.0.0",
      url: "https://example.com/v99",
      prerelease: false,
      date: "2026-10-01",
      assets: [
        %{name: name, url: build, size: File.stat!(build).size},
        %{name: name <> ".sig", url: build <> ".sig", size: nil}
      ]
    }

    pid = start_supervised!(Updates)
    :sys.replace_state(pid, &%{&1 | releases: [release]})

    %{conn: log_in_user(conn, user_fixture()), exe: exe}
  end

  test "the dashboard installs the latest release and offers a restart", %{conn: conn, exe: exe} do
    {:ok, lv, _html} = live(conn, ~p"/scripts")
    assert has_element?(lv, "#install-latest")
    refute has_element?(lv, "#update-install")

    Updates.subscribe()
    lv |> element("#install-latest") |> render_click()
    assert_receive {:update_install, %{stage: :ready}}

    assert has_element?(lv, "#update-install #restart-app")
    assert File.read!(exe) == "new build"
  end

  test "the Peers page says updates install themselves and offers rollback", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/peers")
    assert has_element?(lv, "#self-install-note")
    refute has_element?(lv, "#rollback-update")

    Updates.subscribe()
    :ok = Updates.install("v99.0.0")
    assert_receive {:update_install, %{stage: :ready}}

    assert has_element?(lv, "#rollback-update")
    lv |> element("#rollback-update") |> render_click()
    assert has_element?(lv, "#update-install", "previous version is back")
  end
end
