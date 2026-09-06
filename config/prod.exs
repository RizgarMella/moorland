import Config

# Static assets are digested by `mix assets.deploy` before a release is built.
config :moorland, MoorlandWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Moorland serves plain HTTP on the machine it runs on and to peers that
# reach it directly, so no TLS is forced here. Traffic between installations
# is encrypted at the application layer (see Moorland.Peers.Envelope).

# Mail never leaves the machine: registration and login links are delivered
# to the in-app mailbox at /dev/mailbox, so no mail API client is needed.
config :swoosh, api_client: false

# The database is created and migrated on boot; there is no setup step.
config :moorland, migrate_on_boot: true

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
