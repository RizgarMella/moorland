defmodule Moorland.Updates do
  @moduledoc """
  Checks the project's GitHub releases and powers the in-app update banner:
  a quiet notice when a newer version exists, with a version picker where the
  latest release is highlighted.

  Configure the repo with `config :moorland, :update_repo, "owner/repo"` (or
  the MOORLAND_UPDATE_REPO env var). Unconfigured or offline, the feature
  stays silent. Until packaged builds land, "updating" links to the release
  to pull and restart; one-click swapping arrives with the single-exe build.
  """

  use GenServer
  require Logger

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
              date: String.slice(to_string(release["published_at"] || ""), 0, 10)
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.sort(fn a, b -> newer?(a.tag, b.tag) end)
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
    {:ok, %{releases: [], checked_at: nil, error: nil}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

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

  def handle_info(_msg, state), do: {:noreply, state}

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
