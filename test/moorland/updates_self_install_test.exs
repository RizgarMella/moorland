defmodule Moorland.UpdatesSelfInstallTest do
  # Sets the packaged-build environment variable and app config: not async.
  use ExUnit.Case, async: false

  alias Moorland.Peers.Crypto
  alias Moorland.Updates
  alias Moorland.Updates.Installer

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: dir} do
    platform = Installer.platform()
    if is_nil(platform), do: raise("no build target for this machine")

    %{public: public, private: private} = Crypto.generate_keypair()
    exe = Path.join(dir, "moorland")
    File.write!(exe, "running build")

    # A "release" on disk; the injected downloader copies instead of fetching.
    build = Path.join(dir, "release_build")
    File.write!(build, "new build " <> :crypto.strong_rand_bytes(5000))
    File.write!(build <> ".sig", Installer.sign(build, Crypto.encode_key(private)))

    System.put_env("__BURRITO_BIN_PATH", exe)
    Application.put_env(:moorland, :release_public_key, Crypto.encode_key(public))
    Application.put_env(:moorland, :update_downloader, fn url, path -> File.cp(url, path) end)

    on_exit(fn ->
      System.delete_env("__BURRITO_BIN_PATH")
      Application.put_env(:moorland, :release_public_key, nil)
      Application.delete_env(:moorland, :update_downloader)
    end)

    pid = start_supervised!(Updates)
    Updates.subscribe()

    put_release = fn tag, assets ->
      :sys.replace_state(pid, fn state ->
        %{state | releases: [%{tag: tag, assets: assets}]}
      end)
    end

    assets = [
      %{name: Installer.asset_name(platform), url: build, size: File.stat!(build).size},
      %{name: Installer.asset_name(platform) <> ".sig", url: build <> ".sig", size: nil}
    ]

    %{exe: exe, build: build, assets: assets, put_release: put_release}
  end

  test "installs a signed release over the running file", ctx do
    assert Updates.self_install() == :ok
    ctx.put_release.("v9.0.0", ctx.assets)

    assert Updates.install("v9.0.0") == :ok
    assert_receive {:update_install, %{tag: "v9.0.0", stage: :downloading}}
    assert_receive {:update_install, %{stage: :verifying}}
    assert_receive {:update_install, %{stage: :installing}}
    assert_receive {:update_install, %{tag: "v9.0.0", stage: :ready}}

    assert File.read!(ctx.exe) == File.read!(ctx.build)
    assert File.read!(ctx.exe <> ".previous") == "running build"
    assert Updates.previous?()
    refute File.exists?(Installer.staging_path(ctx.exe))

    assert Updates.rollback() == :ok
    assert_receive {:update_install, %{tag: :previous, stage: :ready}}
    assert File.read!(ctx.exe) == "running build"
  end

  test "refuses a download whose signature does not match", ctx do
    File.write!(ctx.build, "something else entirely", [:append])
    [file, sig] = ctx.assets
    ctx.put_release.("v9.0.0", [%{file | size: File.stat!(ctx.build).size}, sig])

    assert Updates.install("v9.0.0") == :ok
    assert_receive {:update_install, %{stage: :failed, error: :bad_signature}}
    assert File.read!(ctx.exe) == "running build"
    refute Updates.previous?()
    refute File.exists?(Installer.staging_path(ctx.exe))
  end

  test "refuses a short download", ctx do
    [file, sig] = ctx.assets
    ctx.put_release.("v9.0.0", [%{file | size: file.size + 1}, sig])

    assert Updates.install("v9.0.0") == :ok
    assert_receive {:update_install, %{stage: :failed, error: :incomplete_download}}
    assert File.read!(ctx.exe) == "running build"
  end

  test "unsigned releases, unknown tags and missing keys are refused up front", ctx do
    [file, _sig] = ctx.assets
    ctx.put_release.("v9.0.0", [file])
    assert Updates.install("v9.0.0") == {:error, :unsigned}
    assert Updates.install("v8.0.0") == {:error, :unknown_release}

    Application.put_env(:moorland, :release_public_key, nil)
    System.delete_env("MOORLAND_UPDATE_KEY")
    assert Updates.self_install() == {:error, :no_key}
    assert Updates.install("v9.0.0") == {:error, :no_key}

    System.delete_env("__BURRITO_BIN_PATH")
    assert Updates.self_install() == {:error, :not_packaged}
  end
end
