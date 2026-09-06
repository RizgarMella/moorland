defmodule MoorlandWeb.PageControllerTest do
  use MoorlandWeb.ConnCase

  import Moorland.AccountsFixtures

  test "GET / redirects anonymous visitors to log in", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "GET / redirects logged-in users to their scripts", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/scripts"
  end
end
