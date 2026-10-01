defmodule Moorland.Peers.Mdns do
  @moduledoc """
  Claims `moorland-<id>.local` on the local network, so other computers
  (and phones) reach this installation by name instead of by an address
  that changes. A small multicast DNS responder: it listens on
  224.0.0.251:5353 alongside the system's own responder (Bonjour, Avahi),
  answers A questions for its one name with this machine's address on the
  network the question came from, and announces itself on start. `<id>` is
  the start of the installation's fingerprint, so the name is stable and
  distinct per installation.

  Windows 10 and later, macOS, iOS and Android resolve `.local` names out
  of the box; most Linux desktops do through Avahi. If the port can't be
  shared the responder stays quiet and nothing else changes.
  """

  use GenServer
  require Logger

  import Bitwise

  alias Moorland.Peers
  alias Moorland.Peers.{Crypto, MdnsPacket}

  @group {224, 0, 0, 251}
  @mdns_port 5353
  @ttl 120

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "This installation's `.local` name."
  def hostname do
    "moorland-" <> String.slice(Crypto.fingerprint(Peers.identity().public_key), 0, 6) <> ".local"
  end

  @doc "The address to open this installation from another computer, or nil when not claimed."
  def url do
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         name when is_binary(name) <- GenServer.call(pid, :claimed) do
      "http://#{name}:#{Peers.identity().port}"
    else
      _ -> nil
    end
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @mdns_port)
    name = Keyword.get_lazy(opts, :name, &hostname/0) |> String.downcase()

    socket_opts = [
      :binary,
      {:active, true},
      {:reuseaddr, true},
      {:ip, {0, 0, 0, 0}},
      {:multicast_loop, true},
      {:multicast_ttl, 255}
      | reuseport()
    ]

    # A name for a server only this computer can reach would be a dead end.
    result =
      if Keyword.has_key?(opts, :port) or served_on_network?(),
        do: :gen_udp.open(port, socket_opts),
        else: {:error, :loopback_only}

    case result do
      {:ok, socket} ->
        join_group(socket)
        if port == @mdns_port, do: send(self(), {:announce, 2})
        {:ok, %{socket: socket, name: name, port: port}}

      {:error, reason} ->
        Logger.info("#{name} not claimed: mDNS port unavailable (#{inspect(reason)})")
        {:ok, %{socket: nil, name: name, port: port}}
    end
  end

  @doc "Does the web server listen beyond this computer (not 127.0.0.1)?"
  def served_on_network? do
    case MoorlandWeb.Endpoint.config(:http)[:ip] do
      {127, _, _, _} -> false
      {0, 0, 0, 0, 0, 0, 0, 1} -> false
      _ -> true
    end
  end

  # macOS and the BSDs share a UDP port only with SO_REUSEPORT.
  defp reuseport do
    case :os.type() do
      {:unix, os} when os in [:darwin, :freebsd, :openbsd, :netbsd] -> [{:reuseport, true}]
      _ -> []
    end
  end

  # Join the group on every network, not just the default one.
  defp join_group(socket) do
    ifaces = for {ip, _mask} <- local_networks(), do: ip

    for ip <- [{0, 0, 0, 0} | ifaces] do
      :inet.setopts(socket, [{:add_membership, {@group, ip}}])
    end
  end

  @impl true
  def handle_call(:claimed, _from, state),
    do: {:reply, if(state.socket, do: state.name), state}

  @impl true
  def handle_info({:udp, socket, from_ip, from_port, packet}, %{socket: socket} = state) do
    with {:ok, query} <- MdnsPacket.decode_query(packet),
         [_ | _] = asked <- Enum.filter(query.questions, &ours?(&1, state.name)),
         [_ | _] = addresses <- addresses_for(from_ip) do
      cond do
        # A plain resolver asking from its own port wants an ordinary reply.
        from_port != @mdns_port ->
          reply = MdnsPacket.encode_response(state.name, addresses, 10, query)
          :gen_udp.send(socket, from_ip, from_port, reply)

        Enum.any?(asked, & &1.unicast?) ->
          reply = MdnsPacket.encode_response(state.name, addresses, @ttl)
          :gen_udp.send(socket, from_ip, from_port, reply)

        true ->
          reply = MdnsPacket.encode_response(state.name, addresses, @ttl)
          :gen_udp.send(socket, @group, @mdns_port, reply)
      end
    end

    {:noreply, state}
  end

  # Unsolicited announcements, a second apart, so caches pick the name up.
  def handle_info({:announce, n}, %{socket: socket} = state) when socket != nil and n > 0 do
    case local_networks() do
      [] ->
        :ok

      networks ->
        addresses = Enum.map(networks, &elem(&1, 0))

        :gen_udp.send(
          socket,
          @group,
          @mdns_port,
          MdnsPacket.encode_response(state.name, addresses, @ttl)
        )
    end

    Process.send_after(self(), {:announce, n - 1}, 1_000)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{socket: socket, name: name}) when socket != nil do
    # A goodbye (TTL 0) tells caches the name is gone.
    addresses = Enum.map(local_networks(), &elem(&1, 0))

    if addresses != [],
      do:
        :gen_udp.send(socket, @group, @mdns_port, MdnsPacket.encode_response(name, addresses, 0))

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp ours?(%{name: name, type: type, class: class}, ours),
    do:
      name == ours and type in [MdnsPacket.type_a(), MdnsPacket.type_any()] and class in [1, 255]

  @doc """
  The addresses to answer with: this machine's address on the network the
  question came from; any of its addresses when asked from itself or from
  a network it doesn't share.
  """
  def addresses_for(from_ip, networks \\ local_networks()) do
    same = for {ip, mask} <- networks, same_network?(ip, from_ip, mask), do: ip

    cond do
      same != [] -> same
      true -> Enum.map(networks, &elem(&1, 0))
    end
  end

  defp same_network?({a, b, c, d}, {e, f, g, h}, {m1, m2, m3, m4}),
    do:
      (a &&& m1) == (e &&& m1) and (b &&& m2) == (f &&& m2) and (c &&& m3) == (g &&& m3) and
        (d &&& m4) == (h &&& m4)

  defp same_network?(_ip, _from, _mask), do: false

  @doc "This machine's IPv4 addresses with their netmasks, loopback aside."
  def local_networks do
    case :inet.getifaddrs() do
      {:ok, ifaces} ->
        for {_name, opts} <- ifaces,
            flags = opts |> Keyword.get_values(:flags) |> List.flatten(),
            :up in flags and :loopback not in flags,
            {addr, mask} <- pairs(opts),
            do: {addr, mask}

      _ ->
        []
    end
  end

  # getifaddrs lists each address followed by its netmask.
  defp pairs(opts) do
    opts
    |> Enum.chunk_while(
      nil,
      fn
        {:addr, {_, _, _, _} = addr}, _ -> {:cont, {addr, nil}}
        {:netmask, {_, _, _, _} = mask}, {addr, nil} -> {:cont, {addr, mask}, nil}
        _, acc -> {:cont, acc}
      end,
      fn _ -> {:cont, nil} end
    )
  end
end
