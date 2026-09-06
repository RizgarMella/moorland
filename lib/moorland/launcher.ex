defmodule Moorland.Launcher do
  @moduledoc """
  The desktop touch: once the web server is listening, open the user's
  browser on it. Only runs when `:open_browser` is configured (packaged
  builds set it; development and tests do not). Never crashes the app: if
  no browser can be opened, the URL is logged instead.
  """

  require Logger

  def child_spec(_opts) do
    %{id: __MODULE__, start: {Task, :start_link, [&open/0]}, restart: :temporary}
  end

  def open do
    url = MoorlandWeb.Endpoint.url()
    Logger.info("Moorland is running at #{url}")

    if Application.get_env(:moorland, :open_browser, false) do
      case System.get_env("MOORLAND_NO_BROWSER") do
        nil -> launch(url)
        _ -> :ok
      end
    end

    :ok
  end

  defp launch(url) do
    {command, args} =
      case :os.type() do
        {:win32, _} -> {"cmd", ["/c", "start", "", url]}
        {:unix, :darwin} -> {"open", [url]}
        {:unix, _} -> {"xdg-open", [url]}
      end

    case System.cmd(command, args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, _} ->
        Logger.info("could not open a browser (#{String.trim(output)}); open #{url} yourself")
    end
  rescue
    error ->
      Logger.info("could not open a browser (#{Exception.message(error)}); open #{url} yourself")
  end
end
