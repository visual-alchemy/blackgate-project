defmodule BlackgateWeb.RouteController do
  use BlackgateWeb, :controller

  alias Blackgate.Db

  action_fallback BlackgateWeb.FallbackController

  def index(conn, _params) do
    with {:ok, routes} <- Db.get_all_routes() do
      data(conn, routes)
    else
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch routes: #{inspect(error)}"})
    end
  end

  def create(conn, %{"route" => route_params}) do
    with {:ok, route} <- Db.create_route(route_params) do
      conn
      |> put_status(:created)
      |> data(route)
    end
  end

  def show(conn, %{"id" => id}) do
    # :timer.sleep(1500)
    {:ok, route} = Db.get_route(id, true)
    data(conn, route)
  end

  def update(conn, %{"id" => id, "route" => route_params}) do
    was_running = route_is_running?(id)

    with {:ok, route} <- Db.update_route(id, route_params) do
      if was_running do
        Blackgate.restart_route(id)
      end

      data(conn, Map.put(route, "restarted", was_running))
    end
  end

  def delete(conn, %{"id" => id}) do
    with [:ok, :ok] <- Db.delete_route(id) do
      send_resp(conn, :no_content, "")
    end
  end

  def start(conn, %{"route_id" => route_id}) do
    case Blackgate.start_route(route_id) do
      {:ok, _pid} ->
        conn
        |> put_status(:ok)
        |> data(%{status: "started", route_id: route_id})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def stop(conn, %{"route_id" => route_id}) do
    case Blackgate.stop_route(route_id) do
      :ok ->
        conn
        |> put_status(:ok)
        |> data(%{status: "stopped", route_id: route_id})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def restart(conn, %{"route_id" => route_id}) do
    case Blackgate.restart_route(route_id) do
      {:ok, _pid} ->
        conn
        |> put_status(:ok)
        |> data(%{status: "restarted", route_id: route_id})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def stats(conn, %{"route_id" => route_id}) do
    case Blackgate.RouteStatsRegistry.get_stats(route_id) do
      nil ->
        conn
        |> put_status(:ok)
        |> json(%{data: nil, message: "No stats available"})

      %{stats: stats, updated_at: updated_at} ->
        conn
        |> put_status(:ok)
        |> json(%{data: stats, updated_at: updated_at})
    end
  end

  def health(conn, %{"route_id" => route_id}) do
    result =
      case Blackgate.RouteStatsRegistry.get_stats(route_id) do
        nil ->
          %{status: "no_data", reasons: []}

        %{stats: stats} ->
          # Extract key metrics (handle both caller-mode and listener-mode layouts)
          caller = (stats["callers"] || []) |> List.first() || %{}

          bitrate = stats["receive-rate-mbps"] || caller["receive-rate-mbps"] || 0
          rtt = stats["rtt-ms"] || caller["rtt-ms"] || 0
          packets_recv = stats["packets-received"] || caller["packets-received"] || 0
          packets_lost = stats["packets-received-lost"] || caller["packets-received-lost"] || 0

          packet_loss =
            if packets_recv > 0,
              do: packets_lost / (packets_recv + packets_lost) * 100,
              else: 0.0

          reasons = []

          reasons =
            cond do
              packet_loss > 1.0 -> ["Packet loss #{Float.round(packet_loss, 2)}% (critical)" | reasons]
              packet_loss > 0.1 -> ["Packet loss #{Float.round(packet_loss, 2)}% (elevated)" | reasons]
              true -> reasons
            end

          reasons =
            cond do
              rtt > 200 -> ["RTT #{Float.round(rtt * 1.0, 1)}ms (high)" | reasons]
              rtt > 50 -> ["RTT #{Float.round(rtt * 1.0, 1)}ms (elevated)" | reasons]
              true -> reasons
            end

          reasons =
            if bitrate == 0,
              do: ["No stream data received" | reasons],
              else: reasons

          status =
            cond do
              Enum.any?(reasons, &String.contains?(&1, "critical")) -> "critical"
              Enum.any?(reasons, &String.contains?(&1, "No stream")) -> "critical"
              reasons != [] -> "warning"
              true -> "good"
            end

          %{status: status, reasons: reasons, packet_loss: packet_loss, rtt: rtt, bitrate: bitrate}
      end

    json(conn, %{data: result})
  end

  def destination_stats(conn, %{"route_id" => route_id}) do
    sink_stats = Blackgate.RouteStatsRegistry.get_all_sink_stats(route_id)

    conn
    |> put_status(:ok)
    |> json(%{data: sink_stats})
  end

  def bulk_action(conn, %{"action" => action, "route_ids" => route_ids})
      when action in ["start", "stop"] and is_list(route_ids) do
    results =
      Enum.map(route_ids, fn route_id ->
        result =
          case action do
            "start" ->
              case Blackgate.start_route(route_id) do
                {:ok, _pid} -> %{route_id: route_id, status: "started"}
                {:error, reason} -> %{route_id: route_id, error: inspect(reason)}
              end

            "stop" ->
              case Blackgate.stop_route(route_id) do
                :ok -> %{route_id: route_id, status: "stopped"}
                {:error, reason} -> %{route_id: route_id, error: inspect(reason)}
              end
          end

        result
      end)

    conn
    |> put_status(:ok)
    |> json(%{data: results})
  end

  def clone(conn, %{"route_id" => route_id}) do
    with {:ok, route} <- Db.get_route(route_id, true) do
      # Prepare route data for cloning
      destinations = Map.get(route, "destinations", [])

      clone_data =
        route
        |> Map.drop(["id", "created_at", "updated_at", "status", "destinations"])
        |> Map.put("name", "#{route["name"]} (Copy)")
        |> Map.put("status", "stopped")

      with {:ok, new_route} <- Db.create_route(clone_data) do
        # Clone each destination
        Enum.each(destinations, fn dest ->
          dest_data = Map.drop(dest, ["id", "route_id", "created_at", "updated_at"])
          Db.create_destination(new_route["id"], dest_data)
        end)

        {:ok, full_route} = Db.get_route(new_route["id"], true)

        conn
        |> put_status(:created)
        |> data(full_route)
      end
    end
  end

  def tags(conn, _params) do
    case Db.get_all_tags() do
      {:ok, tags} ->
        json(conn, %{data: tags})

      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch tags: #{inspect(error)}"})
    end
  end

  defp route_is_running?(id) do
    case Blackgate.get_route(id) do
      {:ok, _pid} -> true
      _ -> false
    end
  end

  defp data(conn, data), do: json(conn, %{data: data})
end
