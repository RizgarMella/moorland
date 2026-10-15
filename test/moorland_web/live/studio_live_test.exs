defmodule MoorlandWeb.StudioLiveTest do
  use MoorlandWeb.ConnCase

  import Phoenix.LiveViewTest
  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Peers
  alias Moorland.Peers.Crypto
  alias Moorland.Scripts

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: Scope.for_user(user)}
  end

  defp add_peer(scope, name, host) do
    %{public: pub} = Crypto.generate_keypair()
    {:ok, peer} = Peers.add_peer(scope, Crypto.format_code(pub, host, 4000), name)
    peer
  end

  test "the Peers page turns studio mode on and off", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/peers")
    refute has_element?(lv, "#studio-relaying")

    lv |> element("#studio-toggle") |> render_click()
    assert Peers.studio?()
    assert has_element?(lv, "#studio-relaying")

    lv |> element("#studio-toggle") |> render_click()
    refute Peers.studio?()
  end

  test "studio peers are badged, and a share can be routed through one", %{
    conn: conn,
    scope: scope
  } do
    {:ok, studio} = scope |> add_peer("Studio", "10.0.0.2") |> Peers.mark_seen(studio: true)
    member = add_peer(scope, "Bea", "10.0.0.3")
    {:ok, script} = Scripts.create_script(scope, %{title: "Moor"})

    {:ok, lv, _html} = live(conn, ~p"/scripts/#{script.id}")
    lv |> element("#panel-tabs button[phx-value-panel=share]") |> render_click()

    # The route only appears once the peer has the script.
    refute has_element?(lv, "#peer-share-#{member.id} select[name=studio_peer_id]")

    lv
    |> form("#peer-share-#{member.id}", %{"role" => "editor"})
    |> render_change()

    assert has_element?(lv, "#peer-share-#{member.id} select[name=studio_peer_id]")
    # A studio is never offered as a route to itself.
    refute has_element?(lv, "#peer-share-#{studio.id} select[name=studio_peer_id]")

    lv
    |> form("#peer-share-#{member.id}", %{"role" => "editor", "studio_peer_id" => studio.id})
    |> render_change()

    assert Scripts.list_peer_routes(script) == %{member.id => studio.id}
    assert [%{relay: [_]}] = Scripts.peer_list_shared(studio.public_key)
  end
end
