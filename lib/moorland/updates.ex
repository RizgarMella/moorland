defmodule Moorland.Updates do
  @moduledoc """
  Checks the project's GitHub releases and powers the in-app update banner:
  a quiet notice when a newer version exists, with a version picker where the
  latest release is highlighted.

  Configure the repo with `config :moorland, :update_repo, "owner/repo"` (or
  the MOORLAND_UPDATE_REPO env var). Unconfigured or offline, the feature
  stays silent.

  Packaged builds can also install a release themselves (see
  `Moorland.Updates.Installer`): the file for this platform is downloaded,
  its signature checked against the release key (`:release_public_key`, or
  MOORLAND_UPDATE_KEY), and swapped in for the next start, keeping the
  previous build for rollback. Progress is broadcast on the "updates"
  topic. Development and server builds, and builds without a release key,
  keep the download link.
  """

  use GenServer
  require Logger

  alias Moorland.Updates.Installer

  @first_check_ms 10_000
  @check_interval_ms 6 * 60 * 60 * 1000

  ## Public API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def current_version do
    case Application.spec(:moorland, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  def repo do
    Application.get_env(:moorland, :update_repo) || System.get_env("MOORLAND_UPDATE_REPO")
  end

  def status do
    case Process.whereis(__MODULE__) do
      nil -> %{releases: [], checked_at: nil, error: :not_running}
      _pid -> GenServer.call(__MODULE__, :status)
    end
  end

  @doc "Runs a check immediately; returns {:ok, release_count} or {:error, reason}."
  def check_now do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      _pid -> GenServer.call(__MODULE__, :check, 20_000)
    end
  end

  def public_key do
    Application.get_env(:moorland, :release_public_key) || System.get_env("MOORLAND_UPDATE_KEY")
  end

  @doc """
  Can this build install updates itself? `:ok`, or why not:
  `:not_packaged` (a development or server build), `:no_key` (no release
  key to check downloads against), `:no_platform`, `:read_only` (the
  folder holding Moorland cannot be written).
  """
  def self_install do
    exe = Installer.executable()

    cond do
      is_nil(exe) -> {:error, :not_packaged}
      is_nil(public_key()) -> {:error, :no_key}
      is_nil(Installer.platform()) -> {:error, :no_platform}
      not Installer.writable_dir?(exe) -> {:error, :read_only}
      true -> :ok
    end
  end

  def self_install?, do: self_install() == :ok

  @doc "Can the previous build be put back?"
  def previous?, do: Installer.previous?(Installer.executable())

  def subscribe, do: Phoenix.PubSub.subscribe(Moorland.PubSub, "updates")

  @doc "Starts installing a release; progress arrives as `{:update_install, state}`."
  def install(tag) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      _pid -> GenServer.call(__MODULE__, {:install, tag})
    end
  end

  @doc "Puts the previous build back for the next start."
  def rollback do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      _pid -> GenServer.call(__MODULE__, :rollback)
    end
  end

  @doc "Starts the installed build in a moment, and stops this one."
  def restart do
    case Installer.executable() do
      nil ->
        {:error, :not_packaged}

      exe ->
        {cmd, args} = Installer.restart_command(exe)
        System.cmd(cmd, args)
        # Give the page a moment to say goodbye before the server stops.
        Task.start(fn ->
          Process.sleep(500)
          System.stop(0)
        end)

        :ok
    end
  end

  @doc "Data for the dashboard banner, or nil when there is nothing newer."
  def banner_info do
    pick_banner(status().releases, current_version())
  end

  ## Pure logic (unit-tested)

  def normalize(tag) do
    version = tag |> to_string() |> String.trim() |> String.trim_leading("v")

    case String.split(version, ".") do
      [_] -> version <> ".0.0"
      [_, _] -> version <> ".0"
      _ -> version
    end
  end

  def newer?(a, b) do
    with {:ok, va} <- Version.parse(normalize(a)),
         {:ok, vb} <- Version.parse(normalize(b)) do
      Version.compare(va, vb) == :gt
    else
      _ -> false
    end
  end

  @doc "Maps decoded GitHub release JSON to our shape, newest version first."
  def parse_releases(list) when is_list(list) do
    list
    |> Enum.flat_map(fn release ->
      case release do
        %{"tag_name" => tag} when is_binary(tag) and tag != "" ->
          [
            %{
              tag: tag,
              name: release["name"] || tag,
              url: release["html_url"] || "",
              prerelease: release["prerelease"] == true,
              date: String.slice(to_string(release["published_at"] || ""), 0, 10),
              assets: assets(release["assets"])
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.sort(fn a, b -> newer?(a.tag, b.tag) end)
  end

  defp assets(list) do
    Enum.flat_map(List.wrap(list), fn
      %{"name" => name, "browser_download_url" => url} = asset
      when is_binary(name) and is_binary(url) ->
        [%{name: name, url: url, size: asset["size"]}]

      _ ->
        []
    end)
  end

  @doc """
  Builds the banner payload: shown only when the newest stable release is
  ahead of the running version. Every release row carries `latest`/`current`
  markers for the picker.
  """
  def pick_banner(releases, current) do
    stable = Enum.reject(releases, & &1.prerelease)
    latest = List.first(stable) || List.first(releases)

    if latest && newer?(latest.tag, current) do
      rows =
        Enum.map(releases, fn release ->
          release
          |> Map.put(:latest, release.tag == latest.tag)
          |> Map.put(:current, normalize(release.tag) == normalize(current))
        end)

      %{current: current, latest: latest, releases: rows}
    end
  end

  ## GenServer

  @impl true
  def init(nil) do
    Process.send_after(self(), :scheduled_check, @first_check_ms)
    {:ok, %{releases: [], checked_at: nil, error: nil, install: nil}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

  def handle_call({:install, _tag}, _from, %{install: %{stage: stage}} = state)
      when stage in [:downloading, :verifying, :installing] do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:install, tag}, _from, state) do
    with :ok <- self_install(),
         %{} = release <-
           Enum.find(state.releases, &(&1.tag == tag)) || {:error, :unknown_release},
         {:ok, asset} <- Installer.pick_asset(release.assets, Installer.platform()) do
      server = self()
      Task.start(fn -> send(server, {:install_done, tag, run_install(server, tag, asset)}) end)
      {:reply, :ok, put_install(state, %{tag: tag, stage: :downloading, error: nil})}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:rollback, _from, state) do
    case Installer.executable() do
      nil ->
        {:reply, {:error, :not_packaged}, state}

      exe ->
        case Installer.rollback(exe) do
          :ok -> {:reply, :ok, put_install(state, %{tag: :previous, stage: :ready, error: nil})}
          error -> {:reply, error, state}
        end
    end
  end

  def handle_call(:check, _from, state) do
    state = run_check(state)

    reply =
      case state.error do
        nil -> {:ok, length(state.releases)}
        error -> {:error, error}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:scheduled_check, state) do
    state = run_check(state)
    Process.send_after(self(), :scheduled_check, @check_interval_ms)
    {:noreply, state}
  end

  def handle_info({:install_stage, tag, stage}, %{install: %{tag: tag}} = state),
    do: {:noreply, put_install(state, %{state.install | stage: stage})}

  def handle_info({:install_done, tag, :ok}, state),
    do: {:noreply, put_install(state, %{tag: tag, stage: :ready, error: nil})}

  def handle_info({:install_done, tag, {:error, reason}}, state) do
    Logger.warning("installing #{tag} failed: #{inspect(reason)}")
    {:noreply, put_install(state, %{tag: tag, stage: :failed, error: reason})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp put_install(state, install) do
    Phoenix.PubSub.broadcast(Moorland.PubSub, "updates", {:update_install, install})
    %{state | install: install}
  end

  # Download the file and its signature beside the executable, check the
  # signature, swap. Anything left half-done is cleaned up.
  defp run_install(server, tag, asset) do
    exe = Installer.executable()
    staging = Installer.staging_path(exe)
    download = Application.get_env(:moorland, :update_downloader, &download/2)

    result =
      with :ok <- download.(asset.url, staging),
           :ok <- check_size(staging, asset.size),
           sig_path = staging <> ".sig",
           :ok <- download.(asset.sig_url, sig_path),
           send(server, {:install_stage, tag, :verifying}),
           :ok <- Installer.verify(staging, File.read!(sig_path), public_key()),
           send(server, {:install_stage, tag, :installing}) do
        Installer.install(staging, exe)
      end

    File.rm(staging)
    File.rm(staging <> ".sig")
    result
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp check_size(_path, nil), do: :ok

  defp check_size(path, size) do
    case File.stat(path) do
      {:ok, %{size: ^size}} -> :ok
      _ -> {:error, :incomplete_download}
    end
  end

  # Streams a URL to a file, following GitHub's redirect to its file store.
  defp download(url, path) do
    headers = [{~c"user-agent", ~c"moorland-updater"}]
    options = [ssl: ssl_options(), timeout: 600_000, connect_timeout: 10_000, autoredirect: true]

    case :httpc.request(:get, {String.to_charlist(url), headers}, options,
           stream: String.to_charlist(path)
         ) do
      {:ok, :saved_to_file} -> :ok
      {:ok, {{_, status, _}, _, _}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp run_check(state) do
    case fetch_releases() do
      {:ok, releases} ->
        %{state | releases: releases, checked_at: DateTime.utc_now(:second), error: nil}

      {:error, reason} ->
        %{state | checked_at: DateTime.utc_now(:second), error: reason}
    end
  end

  defp fetch_releases do
    case repo() do
      nil ->
        {:error, :not_configured}

      repo ->
        url = String.to_charlist("https://api.github.com/repos/#{repo}/releases?per_page=15")

        headers = [
          {~c"user-agent", ~c"moorland-update-check"},
          {~c"accept", ~c"application/vnd.github+json"}
        ]

        ssl_options = [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          depth: 3,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]

        options = [ssl: ssl_options, timeout: 10_000, connect_timeout: 5_000]

        case :httpc.request(:get, {url, headers}, options, body_format: :binary) do
          {:ok, {{_, 200, _}, _headers, body}} ->
            case Jason.decode(body) do
              {:ok, list} when is_list(list) -> {:ok, parse_releases(list)}
              _ -> {:error, :bad_response}
            end

          {:ok, {{_, 404, _}, _, _}} ->
            {:error, :repo_not_found}

          {:ok, {{_, status, _}, _, _}} ->
            {:error, {:http, status}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  rescue
    error ->
      Logger.warning("update check failed: #{Exception.message(error)}")
      {:error, :check_failed}
  end
end
