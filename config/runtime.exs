import Config

# config/runtime.exs runs for every environment, releases included, after
# compilation and before the system starts. Packaged builds configure
# themselves here: where the data folder is, a secret that persists across
# restarts, and a web server that is always on.

config :moorland, MoorlandWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if System.get_env("PHX_SERVER") do
  config :moorland, MoorlandWeb.Endpoint, server: true
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :moorland, MoorlandWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/moorland_web/router\.ex$",
        ~r"lib/moorland_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  present? = fn value -> is_binary(value) and String.trim(value) != "" end

  # The data folder: MOORLAND_DATA_DIR, else DATABASE_PATH's folder (server
  # deployments), else the pointer file written when a user relocates
  # storage in the app, else the platform's application data folder.
  home = System.user_home!()
  pointer = Path.join(home, ".moorland/data_dir")

  platform_default =
    case :os.type() do
      {:win32, _} ->
        Path.join(System.get_env("LOCALAPPDATA") || Path.join(home, "AppData/Local"), "Moorland")

      {:unix, :darwin} ->
        Path.join(home, "Library/Application Support/Moorland")

      {:unix, _} ->
        Path.join(System.get_env("XDG_DATA_HOME") || Path.join(home, ".local/share"), "moorland")
    end

  pointed =
    with true <- File.exists?(pointer),
         dir when dir != "" <- String.trim(File.read!(pointer)) do
      dir
    else
      _ -> nil
    end

  data_dir =
    cond do
      present?.(System.get_env("MOORLAND_DATA_DIR")) -> System.get_env("MOORLAND_DATA_DIR")
      present?.(System.get_env("DATABASE_PATH")) -> Path.dirname(System.get_env("DATABASE_PATH"))
      pointed -> pointed
      true -> platform_default
    end

  File.mkdir_p!(data_dir)

  config :moorland, Moorland.Repo,
    database: System.get_env("DATABASE_PATH") || Path.join(data_dir, "moorland.db"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # Cookies and tokens are signed with this. SECRET_KEY_BASE wins; otherwise
  # a secret is generated once and kept beside the database, so sessions
  # survive restarts and no setup step is needed.
  secret_key_base =
    case System.get_env("SECRET_KEY_BASE") do
      secret when is_binary(secret) and byte_size(secret) >= 64 ->
        secret

      _ ->
        secret_path = Path.join(data_dir, "secret.key")

        case File.read(secret_path) do
          {:ok, contents} when byte_size(contents) >= 64 ->
            String.trim(contents)

          _ ->
            secret = :crypto.strong_rand_bytes(48) |> Base.encode64()
            File.write!(secret_path, secret)
            secret
        end
    end

  port = String.to_integer(System.get_env("PORT", "4000"))
  host = System.get_env("PHX_HOST") || "localhost"

  # Plain HTTP, reachable from the local network so peers can connect; the
  # peer wire is encrypted at the application layer. The server is on unless
  # PHX_SERVER=false asks for a console-only node.
  config :moorland, MoorlandWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: System.get_env("PHX_SERVER") != "false"

  config :moorland, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Packaged builds open the browser on launch (MOORLAND_NO_BROWSER=1 to
  # skip) and check this project's GitHub releases for updates.
  config :moorland, :open_browser, true

  config :moorland,
         :update_repo,
         System.get_env("MOORLAND_UPDATE_REPO") || "RizgarMella/moorland"
end
