defmodule BlackgateWeb.RouteController do
  use BlackgateWeb, :controller

  alias Blackgate.Db
  alias Blackgate.RouteValidator

  action_fallback BlackgateWeb.FallbackController

  def index(conn, _params) do
    with {:ok, routes} <- Db.get_all_routes(true) do
      enriched_routes =
        Enum.map(routes, fn route ->
          is_connected = route_connected?(route["id"])
          Map.put(route, "connected", is_connected)
        end)

      data(conn, enriched_routes)
    else
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch routes: #{inspect(error)}"})
    end
  end

  defp route_connected?(route_id) do
    case Blackgate.RouteStatsRegistry.get_stats(route_id) do
      %{stats: stats} ->
        callers = Map.get(stats, "callers", [])
        connected_callers = Map.get(stats, "connected-callers", 0)
        receive_mbps = Map.get(stats, "receive-rate-mbps", 0)
        bytes_received = Map.get(stats, "bytes-received", 0)
        total_bytes_received = Map.get(stats, "total-bytes-received", 0)

        caller_mbps =
          case callers do
            [first_caller | _] -> Map.get(first_caller, "receive-rate-mbps", 0)
            _ -> 0
          end

        # In caller mode, connected-callers is 0 and receive-rate-mbps may report 0
        # even when data is flowing. Check bytes-received as a reliable fallback.
        connected_callers > 0 or receive_mbps > 0 or caller_mbps > 0 or
          bytes_received > 0 or total_bytes_received > 0

      nil ->
        false
    end
  end

  def create(conn, %{"route" => route_params}) do
    case RouteValidator.validate(route_params) do
      :ok ->
        with {:ok, route} <- Db.create_route(route_params) do
          conn
          |> put_status(:created)
          |> data(route)
        end

      {:error, errors} ->
        validation_error(conn, errors)
    end
  end

  def show(conn, %{"id" => id}) do
    case Db.get_route(id, true) do
      {:ok, nil} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Route not found"})

      {:ok, route} ->
        data(conn, route)

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: inspect(reason)})
    end
  end

  def update(conn, %{"id" => id, "route" => route_params}) do
    was_running = route_is_running?(id)
    route_params = normalize_failover_params(route_params)

    with {:ok, existing_route} <- Db.get_route(id, true),
         merged_route when is_map(merged_route) <- Map.merge(existing_route || %{}, route_params),
         :ok <- RouteValidator.validate(merged_route),
         {:ok, route} <- Db.update_route(id, route_params) do
      if was_running, do: Blackgate.restart_route(id)
      data(conn, Map.put(route, "restarted", was_running))
    else
      {:error, errors} when is_list(errors) -> validation_error(conn, errors)
      error -> error
    end
  end

  defp validation_error(conn, errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Invalid route configuration", details: errors})
  end

  # Disabling failover must also clear seamless_sdi_failover: the flag is a
  # sub-feature of failover, and the Map.merge with the existing route would
  # otherwise carry a stale true forward and fail validation.
  defp normalize_failover_params(%{"failover_enabled" => false} = params) do
    Map.put(params, "seamless_sdi_failover", false)
  end

  defp normalize_failover_params(params), do: params

  def delete(conn, %{"id" => id}) do
    with [:ok, :ok] <- Db.delete_route(id) do
      send_resp(conn, :no_content, "")
    end
  end

  def start(conn, %{"route_id" => route_id}) do
    case Blackgate.License.can_start_route?() do
      {:error, reason} ->
        conn
        |> put_status(:payment_required)
        |> json(%{error: reason})

      {:ok, :allowed} ->
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

  def switch_source(conn, %{"route_id" => route_id, "target" => target}) do
    cond do
      target not in ["primary", "secondary"] ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid target. Must be 'primary' or 'secondary'."})

      true ->
        {:ok, route} = Db.get_route(route_id, true)

        if failover_enabled?(route) do
          case Blackgate.switch_route_source(route_id, target) do
            :ok ->
              conn
              |> put_status(:accepted)
              |> data(%{status: "switching", requested_source: target})

            {:error, reason} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: inspect(reason)})
          end
        else
          conn
          |> put_status(:bad_request)
          |> json(%{error: "Failover is not enabled for this route"})
        end
    end
  end

  defp failover_enabled?(route) do
    Map.get(route, "failover_enabled") == true
  end

  def stats(conn, %{"route_id" => route_id}) do
    primary = Blackgate.RouteStatsRegistry.get_stats(route_id)

    secondary =
      case Db.get_route(route_id) do
        {:ok, route} when is_map(route) ->
          if failover_enabled?(route) do
            Blackgate.RouteStatsRegistry.get_secondary_stats(route_id)
          else
            Blackgate.RouteStatsRegistry.delete_secondary_stats(route_id)
            nil
          end

        _ ->
          nil
      end

    case primary do
      nil ->
        conn
        |> put_status(:ok)
        |> json(%{data: nil, secondary_source_stats: secondary, message: "No stats available"})

      %{stats: stats, updated_at: updated_at} ->
        conn
        |> put_status(:ok)
        |> json(%{data: stats, updated_at: updated_at, secondary_source_stats: secondary})
    end
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

  def preview(conn, %{"route_id" => route_id}) do
    preview_path = "/tmp/blackgate_preview_#{route_id}.jpg"

    case File.read(preview_path) do
      {:ok, data} ->
        conn
        |> put_resp_content_type("image/jpeg")
        |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
        |> send_resp(200, data)

      {:error, _} ->
        send_resp(conn, 204, "")
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
