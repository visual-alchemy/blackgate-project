defmodule BlackgateWeb.StatsChannel do
  use Phoenix.Channel

  require Logger

  @impl true
  def join("stats:" <> route_id, _params, socket) do
    # Subscribe to PubSub topic for this route so we receive broadcasts
    Phoenix.PubSub.subscribe(Blackgate.PubSub, "route_stats:#{route_id}")
    socket = assign(socket, :route_id, route_id)

    # Send a snapshot of the current stats immediately on join
    snapshot =
      case Blackgate.RouteStatsRegistry.get_stats(route_id) do
        %{stats: stats} -> stats
        nil -> nil
      end

    sink_snapshot = Blackgate.RouteStatsRegistry.get_all_sink_stats(route_id)

    {:ok, %{stats: snapshot, sink_stats: sink_snapshot}, socket}
  end

  @impl true
  def handle_info({:stats_update, stats}, socket) do
    push(socket, "stats_update", %{stats: stats})
    {:noreply, socket}
  end

  def handle_info({:sink_stats_update, sink_index, stats}, socket) do
    push(socket, "sink_stats_update", %{sink_index: sink_index, stats: stats})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
