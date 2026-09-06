defmodule Moorland.Peers.Transport do
  @moduledoc """
  Runtime state for the encrypted wire: this run's key-exchange pair, the kx
  keys learned from peers, and a replay guard over opened envelopes.

  The kx pair lives only in memory and is regenerated every start, so a key
  that leaks can unlock traffic from that one run and nothing before it.
  Peers notice a restart because envelopes sealed to the old key come back
  `stale_kx`; they fetch the new key from `hello` and retry.
  """

  use GenServer

  alias Moorland.Peers
  alias Moorland.Peers.Envelope

  @max_clock_skew_seconds 300
  @replay_table :moorland_peer_replay
  @sweep_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def max_clock_skew_seconds, do: @max_clock_skew_seconds

  @doc "This run's key-exchange pair."
  def kx, do: GenServer.call(__MODULE__, :kx)

  @doc "The kx key last learned for a peer: `{:ok, key}` or `:unknown`."
  def peer_kx(public_key), do: GenServer.call(__MODULE__, {:peer_kx, public_key})

  def remember_peer_kx(public_key, kx),
    do: GenServer.call(__MODULE__, {:remember, public_key, kx})

  def forget_peer_kx(public_key), do: GenServer.call(__MODULE__, {:forget, public_key})

  @doc "This installation's signed hello, fresh each call."
  def hello do
    identity = Peers.identity()
    Envelope.sign_hello(kx().public, identity.public_key, identity.private_key, now())
  end

  @doc "Seals a request (op + args) for a peer whose kx key we hold; stamps the time."
  def seal(peer_kx, request) when is_map(request) do
    request = Map.put(request, :ts, now())
    Envelope.seal(Jason.encode!(request), Peers.identity(), peer_kx)
  end

  @doc """
  Accepts an incoming envelope: known sender, valid signature, addressed to
  this run's kx key, fresh timestamp, and never seen before. Returns the
  decoded request, the peer, and the session to seal the reply with.
  """
  def accept(envelope) do
    with {:ok, plaintext, peer, session} <-
           Envelope.open(envelope, kx(), &Peers.get_by_public_key/1),
         {:ok, request} <- decode_request(plaintext),
         :ok <- check_fresh(request["ts"]),
         :ok <- guard_replay(session.eph, request["ts"]) do
      {:ok, request, peer, session}
    end
  end

  defp decode_request(plaintext) do
    case Jason.decode(plaintext) do
      {:ok, %{} = request} -> {:ok, request}
      _ -> {:error, :malformed}
    end
  end

  defp check_fresh(ts) when is_integer(ts) do
    if abs(now() - ts) <= @max_clock_skew_seconds, do: :ok, else: {:error, :stale}
  end

  defp check_fresh(_ts), do: {:error, :malformed}

  # An ephemeral key is single-use by construction, so seeing one again
  # inside the clock-skew window is a replay.
  defp guard_replay(eph, ts) do
    if :ets.insert_new(@replay_table, {eph, ts + @max_clock_skew_seconds}),
      do: :ok,
      else: {:error, :replay}
  end

  defp now, do: System.system_time(:second)

  ## Server

  @impl true
  def init(nil) do
    :ets.new(@replay_table, [:named_table, :public, :set])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{kx: Envelope.generate_kx(), peers: %{}}}
  end

  @impl true
  def handle_call(:kx, _from, state), do: {:reply, state.kx, state}

  def handle_call({:peer_kx, key}, _from, state) do
    reply =
      case Map.fetch(state.peers, key) do
        {:ok, kx} -> {:ok, kx}
        :error -> :unknown
      end

    {:reply, reply, state}
  end

  def handle_call({:remember, key, kx}, _from, state) do
    {:reply, :ok, %{state | peers: Map.put(state.peers, key, kx)}}
  end

  def handle_call({:forget, key}, _from, state) do
    {:reply, :ok, %{state | peers: Map.delete(state.peers, key)}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now()
    :ets.select_delete(@replay_table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
