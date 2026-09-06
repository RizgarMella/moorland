defmodule Moorland.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MoorlandWeb.Telemetry,
      Moorland.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:moorland, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:moorland, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Moorland.PubSub},
      MoorlandWeb.Presence,
      Moorland.Scripts.ContentCache,
      # Start a worker by calling: Moorland.Worker.start_link(arg)
      # {Moorland.Worker, arg},
      # Start to serve requests, typically the last entry
      Moorland.Peers.Transport,
      MoorlandWeb.Endpoint
    ]

    children =
      if Application.get_env(:moorland, :start_peer_sync, true),
        do: children ++ [Moorland.Peers.Sync, Moorland.Peers.Discovery],
        else: children

    # Backfill the plain-text .fountain mirrors once per boot.
    children =
      if Application.get_env(:moorland, :mirror_scripts, true),
        do: children ++ [{Task, &Moorland.Storage.mirror_all/0}],
        else: children

    children =
      if Application.get_env(:moorland, :start_update_checker, true),
        do: children ++ [Moorland.Updates],
        else: children

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Moorland.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MoorlandWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
