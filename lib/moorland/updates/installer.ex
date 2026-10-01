defmodule Moorland.Updates.Installer do
  @moduledoc """
  Installing a release over the running single-file build.

  Packaged builds are one executable per platform (Burrito), which tells
  the running app where it lives in `__BURRITO_BIN_PATH`. Installing a
  release means: download that platform's file from the GitHub release
  next to the executable, check its Ed25519 signature against the release
  key built into the app, then swap it in. The swap is two renames, which
  every platform allows even while the program runs (Windows refuses to
  overwrite a running .exe but lets it be renamed): the running file
  becomes `<exe>.previous`, kept for rollback, and the new one takes its
  name. The new version runs from the next start.

  Signatures are over the SHA-256 of the file, so large files are hashed
  as a stream. `.sig` files hold the base64 signature.
  """

  alias Moorland.Peers.Crypto

  @assets %{
    "linux" => "moorland_linux",
    "windows" => "moorland_windows.exe",
    "macos" => "moorland_macos",
    "macos_arm" => "moorland_macos_arm"
  }

  @doc "The running single-file executable, or nil when not a packaged build."
  def executable do
    case System.get_env("__BURRITO_BIN_PATH") do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  @doc "This machine's build target, or nil for one no build is made for."
  def platform(os \\ :os.type(), arch \\ to_string(:erlang.system_info(:system_architecture))) do
    cond do
      match?({:win32, _}, os) -> "windows"
      os == {:unix, :darwin} and String.starts_with?(arch, "aarch64") -> "macos_arm"
      os == {:unix, :darwin} -> "macos"
      match?({:unix, :linux}, os) and String.starts_with?(arch, "x86_64") -> "linux"
      true -> nil
    end
  end

  def asset_name(platform), do: Map.get(@assets, platform)

  @doc """
  The platform's file and its signature among a release's assets:
  `{:ok, %{url, size, sig_url}}`, `{:error, :no_build}` when the release has
  no file for this platform, `{:error, :unsigned}` when it has no signature.
  """
  def pick_asset(assets, platform) do
    name = asset_name(platform)
    by_name = Map.new(assets || [], &{&1.name, &1})

    case {by_name[name], by_name[name <> ".sig"]} do
      {nil, _} -> {:error, :no_build}
      {_file, nil} -> {:error, :unsigned}
      {file, sig} -> {:ok, %{url: file.url, size: file.size, sig_url: sig.url}}
    end
  end

  @doc "SHA-256 of a file, read as a stream."
  def digest(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
  end

  @doc "Signs a file's digest with a base64url Ed25519 private key; returns the base64 signature."
  def sign(path, private_key_b64) do
    {:ok, private_key} = Crypto.decode_key(String.trim(private_key_b64))
    path |> digest() |> Crypto.sign(private_key) |> Base.encode64()
  end

  @doc "Checks a file against a base64 signature and a base64url public key."
  def verify(path, signature_b64, public_key_b64) do
    with {:ok, signature} <- Base.decode64(String.trim(signature_b64)),
         {:ok, public_key} <- Crypto.decode_key(String.trim(public_key_b64)),
         true <- Crypto.verify(digest(path), signature, public_key) do
      :ok
    else
      _ -> {:error, :bad_signature}
    end
  end

  @doc "Where a download is staged: beside the executable, so the swap is a rename."
  def staging_path(exe), do: Path.join(Path.dirname(exe), ".#{Path.basename(exe)}.download")

  def previous_path(exe), do: exe <> ".previous"

  @doc "Can files be written beside the executable (the swap needs to)?"
  def writable_dir?(exe) do
    probe = Path.join(Path.dirname(exe), ".moorland-write-test")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        true

      _ ->
        false
    end
  end

  @doc """
  Puts `new_file` in place of `exe`, keeping the running file as
  `<exe>.previous`. If the second rename fails the first is undone, so
  there is always a runnable file at `exe`.
  """
  def install(new_file, exe) do
    previous = previous_path(exe)
    File.rm(previous)
    File.chmod(new_file, 0o755)

    with :ok <- File.rename(exe, previous) do
      case File.rename(new_file, exe) do
        :ok ->
          :ok

        {:error, reason} ->
          File.rename(previous, exe)
          {:error, reason}
      end
    end
  end

  @doc "Swaps the previous build back in (and keeps the current one as previous)."
  def rollback(exe) do
    previous = previous_path(exe)
    swap = exe <> ".swap"

    with true <- File.exists?(previous) || {:error, :no_previous},
         :ok <- File.rename(exe, swap),
         :ok <- restore(File.rename(previous, exe), swap, exe) do
      File.rename(swap, previous)
    end
  end

  defp restore(:ok, _swap, _exe), do: :ok

  defp restore(error, swap, exe) do
    File.rename(swap, exe)
    error
  end

  @doc "Is there a previous build to roll back to?"
  def previous?(nil), do: false
  def previous?(exe), do: File.exists?(previous_path(exe))

  @doc """
  The command that starts `exe` again a few seconds from now. It returns at
  once, leaving a detached process to wait, so this program can stop and
  free the port before the new one starts.
  """
  def restart_command(exe, os \\ :os.type())

  def restart_command(exe, {:win32, _}) do
    {"cmd.exe",
     ["/c", "start \"\" /b cmd /c \"timeout /t 3 /nobreak >nul & start \"\" \"#{exe}\"\""]}
  end

  def restart_command(exe, _unix) do
    {"/bin/sh", ["-c", "(sleep 3; nohup \"$0\" &) </dev/null >/dev/null 2>&1 &", exe]}
  end
end
