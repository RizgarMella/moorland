defmodule Mix.Tasks.Moorland.Sign do
  @shortdoc "Signs release files for self-installing updates"
  @moduledoc """
  Writes `<file>.sig` beside each file: the Ed25519 signature of its
  SHA-256, made with the private key in `MOORLAND_RELEASE_KEY`.

      MOORLAND_RELEASE_KEY=... mix moorland.sign burrito_out/moorland_linux

  Packaged copies install a release only when its signature checks out
  against the public key they were built with.
  """
  use Mix.Task

  alias Moorland.Updates.Installer

  @impl true
  def run(files) do
    key =
      System.get_env("MOORLAND_RELEASE_KEY") ||
        Mix.raise("Set MOORLAND_RELEASE_KEY to the release private key.")

    if files == [], do: Mix.raise("Name the files to sign.")

    for file <- files do
      File.regular?(file) || Mix.raise("No such file: #{file}")
      File.write!(file <> ".sig", Installer.sign(file, key))
      Mix.shell().info("signed #{file}")
    end
  end
end
