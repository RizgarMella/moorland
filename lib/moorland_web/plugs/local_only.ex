defmodule MoorlandWeb.LocalOnly do
  @moduledoc """
  Lets a request through only when it comes from the machine Moorland is
  running on. Used for the in-app mailbox, which shows login links for local
  accounts and must not be readable by anyone else on the network.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{remote_ip: {127, _, _, _}} = conn, _opts), do: conn
  def call(%Plug.Conn{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}} = conn, _opts), do: conn
  # IPv4 loopback seen through an IPv6 socket (::ffff:127.x.x.x).
  def call(%Plug.Conn{remote_ip: {0, 0, 0, 0, 0, 65_535, 32_512, _}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "This page is only available on the computer running Moorland.")
    |> halt()
  end
end
