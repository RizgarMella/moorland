defmodule MoorlandWeb.Router do
  use MoorlandWeb, :router

  import MoorlandWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MoorlandWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", MoorlandWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # The encrypted peer-to-peer wire between Moorland installations; the
  # protocol lives in Moorland.Peers.Envelope.
  scope "/peer/api", MoorlandWeb do
    pipe_through :api

    get "/hello", PeerApiController, :hello
    post "/envelope", PeerApiController, :envelope
  end

  # The in-app mailbox. Registration and login links are delivered here, so
  # Moorland needs no mail server; only the machine running it may look.
  pipeline :local_only do
    plug MoorlandWeb.LocalOnly
  end

  scope "/dev" do
    pipe_through [:browser, :local_only]

    forward "/mailbox", Plug.Swoosh.MailboxPreview
  end

  # LiveDashboard, development only.
  if Application.compile_env(:moorland, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MoorlandWeb.Telemetry
    end
  end

  ## Authentication routes

  scope "/", MoorlandWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{MoorlandWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      live "/scripts", ScriptLive.Index, :index
      live "/scripts/:id", ScriptLive.Editor, :edit
      live "/peers", PeerLive.Index, :index
      live "/contacts", ContactLive.Index, :index
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", MoorlandWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{MoorlandWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
