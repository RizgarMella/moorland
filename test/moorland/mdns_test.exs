defmodule Moorland.MdnsTest do
  use ExUnit.Case, async: true

  alias Moorland.Peers.{Mdns, MdnsPacket}

  describe "packets" do
    test "a query reads back, compressed names included" do
      {:ok, query} =
        "Moorland-ABC123.local" |> MdnsPacket.encode_query(7, true) |> MdnsPacket.decode_query()

      assert query.id == 7

      assert [%{name: "moorland-abc123.local", type: 1, unicast?: true, class: 1}] =
               query.questions

      # Two questions, the second pointing back at the first's "local".
      packet =
        <<0::16, 0::16, 2::16, 0::16, 0::16, 0::16>> <>
          <<1, "a", 5, "local", 0, 1::16, 1::16>> <>
          <<1, "b", 0xC0, 14, 1::16, 1::16>>

      assert {:ok, %{questions: [%{name: "a.local"}, %{name: "b.local"}]}} =
               MdnsPacket.decode_query(packet)
    end

    test "responses, malformed packets and pointer loops are ignored" do
      response = MdnsPacket.encode_response("x.local", [{10, 0, 0, 5}], 120)
      assert MdnsPacket.decode_query(response) == :ignore
      assert MdnsPacket.decode_query(<<1, 2, 3>>) == :ignore

      looping = <<0::16, 0::16, 1::16, 0::16, 0::16, 0::16, 0xC0, 12, 1::16, 1::16>>
      assert MdnsPacket.decode_query(looping) == :ignore
    end

    test "a response carries an A record per address" do
      response = MdnsPacket.encode_response("x.local", [{10, 0, 0, 5}, {192, 168, 1, 9}], 120)

      assert MdnsPacket.decode_answers(response) == [
               {"x.local", {10, 0, 0, 5}},
               {"x.local", {192, 168, 1, 9}}
             ]

      # Answering a plain resolver echoes its id and question.
      {:ok, query} = MdnsPacket.decode_query(MdnsPacket.encode_query("x.local", 4242))

      <<4242::16, _flags::16, 1::16, 1::16, _::binary>> =
        reply = MdnsPacket.encode_response("x.local", [{10, 0, 0, 5}], 10, query)

      assert MdnsPacket.decode_answers(reply) == [{"x.local", {10, 0, 0, 5}}]
    end
  end

  test "answers with the address on the asker's network" do
    networks = [{{192, 168, 1, 20}, {255, 255, 255, 0}}, {{10, 8, 0, 3}, {255, 255, 0, 0}}]
    assert Mdns.addresses_for({192, 168, 1, 77}, networks) == [{192, 168, 1, 20}]
    assert Mdns.addresses_for({10, 8, 44, 1}, networks) == [{10, 8, 0, 3}]
    assert Mdns.addresses_for({127, 0, 0, 1}, networks) == [{192, 168, 1, 20}, {10, 8, 0, 3}]
  end

  test "a responder answers a resolver's question for its name, and only its name" do
    port = 20_000 + :rand.uniform(20_000)
    start_supervised!({Mdns, port: port, name: "moorland-test01.local"})

    if Mdns.local_networks() == [] do
      # No network to answer for (a bare container): nothing to send.
      :ok
    else
      {:ok, socket} = :gen_udp.open(0, [:binary, active: false])

      :ok =
        :gen_udp.send(
          socket,
          {127, 0, 0, 1},
          port,
          MdnsPacket.encode_query("someone-else.local", 1)
        )

      :ok =
        :gen_udp.send(
          socket,
          {127, 0, 0, 1},
          port,
          MdnsPacket.encode_query("MOORLAND-test01.local", 2)
        )

      assert {:ok, {_ip, ^port, reply}} = :gen_udp.recv(socket, 0, 2_000)
      assert <<2::16, _::binary>> = reply
      assert [{"moorland-test01.local", {_, _, _, _}} | _] = MdnsPacket.decode_answers(reply)
      assert {:error, :timeout} = :gen_udp.recv(socket, 0, 200)
    end
  end

  describe "networks changing" do
    @home {{192, 168, 1, 20}, {255, 255, 255, 0}}
    @vpn {{10, 8, 0, 3}, {255, 255, 0, 0}}

    test "only a real change calls for joining or announcing" do
      assert Mdns.network_changes([@home, @vpn], [@vpn, @home]) == {[], false}
      assert Mdns.network_changes([@home], [@home, @vpn]) == {[{10, 8, 0, 3}], true}
      # A new address on the same network (DHCP renewed differently).
      assert Mdns.network_changes([@home], [{{192, 168, 1, 31}, {255, 255, 255, 0}}]) ==
               {[{192, 168, 1, 31}], true}

      assert Mdns.network_changes([@home, @vpn], [@home]) == {[], true}
      # Nowhere left to announce to.
      assert Mdns.network_changes([@home], []) == {[], false}
      # Woke before the Wi-Fi: the first network to appear is joined.
      assert Mdns.network_changes([], [@home]) == {[{192, 168, 1, 20}], true}
    end

    test "the responder notices networks that appear after it started" do
      nets = start_supervised!({Agent, fn -> [] end})

      start_supervised!(
        {Mdns,
         port: 20_000 + :rand.uniform(20_000),
         name: "moorland-test02.local",
         networks: fn -> Agent.get(nets, & &1) end,
         watch_ms: nil}
      )

      assert :sys.get_state(Mdns).seen == []

      Agent.update(nets, fn _ -> [@home] end)
      send(Mdns, :watch)
      assert :sys.get_state(Mdns).seen == [@home]
    end
  end

  test "without a readable identity it stays quiet instead of crashing" do
    # This process holds no database checkout, so the identity can't be read.
    start_supervised!({Mdns, port: 20_000 + :rand.uniform(20_000)})

    assert :sys.get_state(Mdns).socket == nil
    assert Mdns.url() == nil
  end
end
