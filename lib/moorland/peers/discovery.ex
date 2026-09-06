defmodule Moorland.Peers.Discovery do
  @moduledoc """
  Zero-config LAN discovery: every install broadcasts a small signed-identity
  beacon over UDP and listens for others, so nearby Moorland installations
  appear on the Peers page with no code pasting. (The mDNS `.local` hostname
  arrives with single-exe packaging; this beacon needs no dependencies.)
  """

  use GenServer
  require Logger

  alias Moorland.Peers
  alias Moorland.Peers.Crypto

  @port 47_474
  @beacon_interval_ms 10_000
  @stale_after_seconds 45

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Nearby installations: [%{public_key, name, host, port, seen_at}]."
  def nearby do
    case Process.whereis(__MODULE__) do
      nil -> []
      _pid -> GenServer.call(__MODULE__, :nearby)
    end
  end

  @impl true
  def init(nil) do
    case :gen_udp.open(@port, [
           :binary,
           {:active, true},
           {:reuseaddr, true},
           {:broadcast, true}
         ]) do
      {:ok, socket} ->
        Process.send_after(self(), :beacon, 2_000)
        {:ok, %{socket: socket, seen: %{}}}

      {:error, reason} ->
        Logger.info("LAN discovery disabled (#{inspect(reason)})")
        {:ok, %{socket: nil, seen: %{}}}
    end
  end

  @impl true
  def handle_call(:nearby, _from, state) do
    cutoff = System.system_time(:second) - @stale_after_seconds

    nearby =
      state.seen
      |> Map.values()
      |> Enum.filter(&(&1.seen_at >= cutoff))
      |> Enum.sort_by(& &1.name)

    {:reply, nearby,
     %{state | seen: Map.filter(state.seen, fn {_k, v} -> v.seen_at >= cutoff end)}}
  end

  @impl true
  def handle_info(:beacon, %{socket: nil} = state), do: {:noreply, state}

  def handle_info(:beacon, state) do
    identity = Peers.identity()

    beacon =
      Jason.encode!(%{
        moorland: 1,
        key: Crypto.encode_key(identity.public_key),
        name: identity.name,
        port: identity.port
      })

    :gen_udp.send(state.socket, {255, 255, 255, 255}, @port, beacon)
    Process.send_after(self(), :beacon, @beacon_interval_ms)
    {:noreply, state}
  rescue
    _ ->
      Process.send_after(self(), :beacon, @beacon_interval_ms)
      {:noreply, state}
  end

  def handle_info({:udp, _socket, ip, _port, data}, state) do
    with {:ok, %{"moorland" => 1, "key" => key64, "name" => name, "port" => port}} <-
           Jason.decode(data),
         {:ok, public_key} <- Crypto.decode_key(key64),
         32 <- byte_size(public_key),
         true <- public_key != Peers.identity().public_key,
         true <- is_integer(port) and port in 1..65_535 do
      entry = %{
        public_key: public_key,
        name: String.slice(to_string(name), 0, 80),
        host: :inet.ntoa(ip) |> to_string(),
        port: port,
        seen_at: System.system_time(:second)
      }

      {:noreply, put_in(state.seen[public_key], entry)}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
