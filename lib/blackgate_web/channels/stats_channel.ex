defmodule BlackgateWeb.StatsChannel do
  use Phoenix.Channel

  require Logger

  @impl true
  def join("route:stats:" <> route_id, _params, socket) do
    # Subscribe to PubSub topic for this route
    Phoenix.PubSub.subscribe(Blackgate.PubSub, "route:stats:#{route_id}")

    send(self(), :after_join)
    {:ok, assign(socket, :route_id, route_id)}
  end

  @impl true
  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown topic"}}

  @impl true
  def handle_info(:after_join, socket) do
    route_id = socket.assigns.route_id
    case Blackgate.RouteStatsRegistry.get_stats(route_id) do
      %{stats: stats, updated_at: updated_at} ->
        health = Blackgate.RouteHealth.evaluate(stats)
        push(socket, "stats_update", %{stats: stats, health: health, updated_at: updated_at})

      nil ->
        :ok
    end
    {:noreply, socket}
  end

  @impl true
  def handle_info({:stats_update, payload}, socket) do
    push(socket, "stats_update", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("StatsChannel unhandled info: #{inspect(msg)}")
    {:noreply, socket}
  end
end
