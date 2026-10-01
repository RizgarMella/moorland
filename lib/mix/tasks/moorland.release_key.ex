defmodule Mix.Tasks.Moorland.ReleaseKey do
  @shortdoc "Generates the Ed25519 key pair that signs release builds"
  @moduledoc """
  Generates the key pair that signs release builds, so packaged copies of
  Moorland can trust the updates they install.

      mix moorland.release_key

  Put the private key in the repository's Actions secrets as
  `MOORLAND_RELEASE_KEY`; the release workflow signs each build with it.
  Put the public key in `config/config.exs` as `:release_public_key`, so
  builds carry it. Keep the private key nowhere else: anyone holding it
  can publish updates your users' copies will install.
  """
  use Mix.Task

  alias Moorland.Peers.Crypto

  @impl true
  def run(_args) do
    keys = Crypto.generate_keypair()

    Mix.shell().info("""
    Public key (config :moorland, :release_public_key):
      #{Crypto.encode_key(keys.public)}

    Private key (GitHub secret MOORLAND_RELEASE_KEY; keep it secret):
      #{Crypto.encode_key(keys.private)}
    """)
  end
end
