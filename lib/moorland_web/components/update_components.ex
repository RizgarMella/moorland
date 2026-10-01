defmodule MoorlandWeb.UpdateComponents do
  @moduledoc """
  Self-installing updates in the UI: the live install status (downloading,
  checking the signature, ready to restart) with Restart and Roll back, and
  the events behind them, shared by the dashboard and the Peers page.
  """
  use MoorlandWeb, :html

  alias Moorland.Updates

  @doc "Assigns what the install UI needs; call on mount (and subscribe when connected)."
  def assign_updates(socket) do
    socket
    |> assign(:install, Updates.status()[:install])
    |> assign(:self_install, Updates.self_install())
    |> assign(:previous_build, Updates.previous?())
  end

  @doc "Handles install_update, restart_app and rollback_update for any LiveView."
  def handle_update_event("install_update", %{"tag" => tag}, socket) do
    case Updates.install(tag) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, install_error(reason))}
    end
  end

  def handle_update_event("restart_app", _params, socket) do
    case Updates.restart() do
      :ok ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :info,
           "Restarting… this page will reconnect in a few seconds."
         )}

      {:error, _} ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           "Restart Moorland yourself to use the new version."
         )}
    end
  end

  def handle_update_event("rollback_update", _params, socket) do
    case Updates.rollback() do
      :ok ->
        {:noreply, assign(socket, :previous_build, Updates.previous?())}

      {:error, _} ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, "There is no previous version to go back to.")}
    end
  end

  def install_error(:not_packaged),
    do: "Only the downloadable app installs updates itself; pull the release instead."

  def install_error(:no_key),
    do: "This build has no release key to check downloads with; download the release instead."

  def install_error(:read_only),
    do:
      "Moorland can't write to the folder it lives in; download the release and replace it yourself."

  def install_error(:no_build), do: "That release has no build for this computer."

  def install_error(:unsigned),
    do: "That release isn't signed, so it won't be installed automatically."

  def install_error(:bad_signature),
    do: "The download's signature didn't match. Nothing was installed."

  def install_error(:incomplete_download),
    do: "The download didn't finish. Nothing was installed."

  def install_error(:busy), do: "An update is already being installed."

  def install_error(:unknown_release),
    do: "That version isn't in the list any more; check for updates again."

  def install_error(_), do: "The update couldn't be installed. Nothing was changed."

  attr :install, :any, required: true
  attr :previous_build, :boolean, default: false

  def install_status(assigns) do
    ~H"""
    <div
      :if={@install}
      id="update-install"
      class={[
        "mt-3 flex flex-wrap items-center gap-2 rounded-lg border px-4 py-2.5 text-sm",
        @install.stage == :failed && "border-error/40 bg-error/5",
        @install.stage == :ready && "border-success/40 bg-success/5",
        @install.stage not in [:failed, :ready] && "border-base-300 bg-base-200/40"
      ]}
    >
      <%= case @install.stage do %>
        <% :ready -> %>
          <.icon name="hero-check-circle" class="size-4 text-success" />
          <span class="min-w-0 flex-1">
            {if @install.tag == :previous,
              do: "The previous version is back in place.",
              else: "Moorland #{@install.tag} is installed."} It runs from the next start.
          </span>
          <button
            id="restart-app"
            type="button"
            phx-click="restart_app"
            class="btn btn-neutral btn-xs"
          >
            Restart now
          </button>
        <% :failed -> %>
          <.icon name="hero-exclamation-triangle" class="size-4 text-error" />
          <span class="min-w-0 flex-1">{install_error(@install.error)}</span>
        <% stage -> %>
          <span class="loading loading-spinner loading-xs"></span>
          <span class="min-w-0 flex-1">
            {case stage do
              :downloading -> "Downloading Moorland #{@install.tag}…"
              :verifying -> "Checking its signature…"
              :installing -> "Installing…"
            end}
          </span>
      <% end %>
    </div>
    """
  end
end
