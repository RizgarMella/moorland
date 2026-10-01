defmodule Moorland.Updates.InstallerTest do
  use ExUnit.Case, async: true

  alias Moorland.Peers.Crypto
  alias Moorland.Updates.Installer

  @moduletag :tmp_dir

  defp keys do
    %{public: public, private: private} = Crypto.generate_keypair()
    {Crypto.encode_key(public), Crypto.encode_key(private)}
  end

  test "a signed file verifies; a changed file or another key does not", %{tmp_dir: dir} do
    {public, private} = keys()
    {other_public, _} = keys()
    file = Path.join(dir, "moorland_linux")
    File.write!(file, :crypto.strong_rand_bytes(200_000))

    signature = Installer.sign(file, private)
    assert Installer.verify(file, signature, public) == :ok
    assert Installer.verify(file, signature, other_public) == {:error, :bad_signature}
    assert Installer.verify(file, "not base64!", public) == {:error, :bad_signature}

    File.write!(file, "tampered", [:append])
    assert Installer.verify(file, signature, public) == {:error, :bad_signature}
  end

  test "digest streams to the same SHA-256 as hashing at once", %{tmp_dir: dir} do
    file = Path.join(dir, "big")
    data = :crypto.strong_rand_bytes(300_000)
    File.write!(file, data)
    assert Installer.digest(file) == :crypto.hash(:sha256, data)
  end

  test "pick_asset finds this platform's file and insists on a signature" do
    assets = [
      %{name: "moorland_linux", url: "https://x/l", size: 10},
      %{name: "moorland_linux.sig", url: "https://x/l.sig", size: 88},
      %{name: "moorland_windows.exe", url: "https://x/w", size: 12}
    ]

    assert {:ok, %{url: "https://x/l", size: 10, sig_url: "https://x/l.sig"}} =
             Installer.pick_asset(assets, "linux")

    assert Installer.pick_asset(assets, "windows") == {:error, :unsigned}
    assert Installer.pick_asset(assets, "macos") == {:error, :no_build}
    assert Installer.pick_asset([], "linux") == {:error, :no_build}
  end

  test "platform maps OS and architecture to a build target" do
    assert Installer.platform({:win32, :nt}, "win32") == "windows"
    assert Installer.platform({:unix, :darwin}, "aarch64-apple-darwin23") == "macos_arm"
    assert Installer.platform({:unix, :darwin}, "x86_64-apple-darwin23") == "macos"
    assert Installer.platform({:unix, :linux}, "x86_64-pc-linux-gnu") == "linux"
    assert Installer.platform({:unix, :linux}, "aarch64-unknown-linux-gnu") == nil
  end

  test "install swaps the new file in and keeps the old one; rollback swaps back",
       %{tmp_dir: dir} do
    exe = Path.join(dir, "moorland")
    File.write!(exe, "v1")
    new = Installer.staging_path(exe)
    File.write!(new, "v2")

    refute Installer.previous?(exe)
    assert Installer.install(new, exe) == :ok
    assert File.read!(exe) == "v2"
    assert File.read!(Installer.previous_path(exe)) == "v1"
    refute File.exists?(new)
    assert Installer.previous?(exe)
    assert File.stat!(exe).mode |> Bitwise.band(0o111) != 0

    assert Installer.rollback(exe) == :ok
    assert File.read!(exe) == "v1"
    assert File.read!(Installer.previous_path(exe)) == "v2"
  end

  test "a failed install leaves the running file in place", %{tmp_dir: dir} do
    exe = Path.join(dir, "moorland")
    File.write!(exe, "v1")

    assert {:error, :enoent} = Installer.install(Path.join(dir, "missing"), exe)
    assert File.read!(exe) == "v1"
  end

  test "rollback with nothing to go back to", %{tmp_dir: dir} do
    exe = Path.join(dir, "moorland")
    File.write!(exe, "v1")
    assert Installer.rollback(exe) == {:error, :no_previous}
    assert File.read!(exe) == "v1"
  end

  test "restart commands detach and name the executable" do
    assert {"/bin/sh", ["-c", script, "/opt/moorland"]} =
             Installer.restart_command("/opt/moorland", {:unix, :linux})

    assert script =~ "sleep 3"
    assert script =~ "nohup"

    assert {"cmd.exe", ["/c", line]} =
             Installer.restart_command(~S"C:\Apps\moorland.exe", {:win32, :nt})

    assert line =~ ~S"C:\Apps\moorland.exe"
  end
end
