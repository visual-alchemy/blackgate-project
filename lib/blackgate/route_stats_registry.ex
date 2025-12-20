defmodule Blackgate.RouteStatsRegistry do
  @moduledoc """
  ETS-based registry to store the latest stats for each running route.
  Stats are updated by UnixSockHandler and read by the API.
  """

  use GenServer
  require Logger

  @table_name :route_stats

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Store stats for a route. Called by UnixSockHandler.
  """
  def put_stats(route_id, stats) when is_binary(route_id) and is_map(stats) do
    :ets.insert(@table_name, {route_id, stats, System.system_time(:millisecond)})
    :ok
  end

  @doc """
  Get stats for a route. Returns nil if not found.
  """
  def get_stats(route_id) when is_binary(route_id) do
    case :ets.lookup(@table_name, route_id) do
      [{^route_id, stats, timestamp}] ->
        %{stats: stats, updated_at: timestamp}

      [] ->
        nil
    end
  end

  @doc """
  Delete stats for a route. Called when route stops.
  """
  def delete_stats(route_id) when is_binary(route_id) do
    :ets.delete(@table_name, route_id)
    :ok
  end

  @doc """
  Clear all stats. Useful for cleanup.
  """
  def clear_all do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc """
  Store stats for a destination/sink. Called by UnixSockHandler.
  Key format: {route_id, :sink, sink_index}
  """
  def put_sink_stats(route_id, sink_index, stats) when is_binary(route_id) and is_map(stats) do
    key = {route_id, :sink, sink_index}
    :ets.insert(@table_name, {key, stats, System.system_time(:millisecond)})
    :ok
  end

  @doc """
  Get stats for a specific sink. Returns nil if not found.
  """
  def get_sink_stats(route_id, sink_index) when is_binary(route_id) do
    key = {route_id, :sink, sink_index}
    case :ets.lookup(@table_name, key) do
      [{^key, stats, timestamp}] ->
        %{stats: stats, updated_at: timestamp}

      [] ->
        nil
    end
  end

  @doc """
  Get stats for all sinks of a route.
  """
  def get_all_sink_stats(route_id) when is_binary(route_id) do
    # Match all keys of format {route_id, :sink, _}
    pattern = {{route_id, :sink, :_}, :_, :_}
    :ets.match_object(@table_name, pattern)
    |> Enum.map(fn {{^route_id, :sink, sink_index}, stats, timestamp} ->
      %{sink_index: sink_index, stats: stats, updated_at: timestamp}
    end)
    |> Enum.sort_by(& &1.sink_index)
  end
end
