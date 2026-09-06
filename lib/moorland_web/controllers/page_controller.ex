defmodule MoorlandWeb.PageController do
  use MoorlandWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_scope] do
      redirect(conn, to: ~p"/scripts")
    else
      redirect(conn, to: ~p"/users/log-in")
    end
  end
end
