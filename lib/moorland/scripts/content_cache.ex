defmodule Moorland.Scripts.ContentCache do
  @moduledoc """
  Keeps recent saved contents per script (keyed by content_version) so a stale
  save can be three-way merged against the exact base its author started from.
  Also provides a per-script lock so concurrent saves serialize their
  read-merge-write cycle instead of racing.
  """

  use GenServer

  @table __MODULE__
  @keep_versions 200

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, nil}
  end

  def get(script_id, version) do
    case :ets.lookup(@table, {script_id, version}) do
      [{_, content}] -> content
      [] -> nil
    end
  end

  def put(script_id, version, content) do
    :ets.insert(@table, {{script_id, version}, content})

    if version >= @keep_versions do
      :ets.delete(@table, {script_id, version - @keep_versions})
    end

    :ok
  end

  @doc """
  Runs `fun` (in the caller's process) holding a node-wide lock for the
  script, so save decisions never interleave.
  """
  def locked(script_id, fun) do
    :global.trans({{__MODULE__, script_id}, self()}, fun, [Node.self()], :infinity)
  end
end
