defmodule MoorlandWeb.LocalOnlyTest do
  use MoorlandWeb.ConnCase

  test "the mailbox answers the machine Moorland runs on", %{conn: conn} do
    conn = %{conn | remote_ip: {127, 0, 0, 1}} |> get("/dev/mailbox")
    assert conn.status == 200
  end

  test "the mailbox refuses everyone else", %{conn: conn} do
    conn = %{conn | remote_ip: {192, 168, 1, 20}} |> get("/dev/mailbox")
    assert conn.status == 403
    assert conn.resp_body =~ "only available on the computer running Moorland"
  end
end
