defmodule BlackgateWeb.RouteController do
  use BlackgateWeb, :controller

  alias Blackgate.Db

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
    with {:ok, route} <- Db.create_route(route_params) do
      conn
      |> put_status(:created)
      |> data(route)
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

    with {:ok, route} <- Db.update_route(id, route_params) do
      if was_running do
        Blackgate.restart_route(id)
      end

      data(conn, Map.put(route, "restarted", was_running))
    end
  end

  def delete(conn, %{"id" => id}) do
    # Stop it before dropping the records. Db.delete_route/1 only removes rows, so a route that was still
    # running kept its engine process alive: the engine held its SDI device and appeared in Settings > System
    # > Pipelines as a row whose route could no longer be resolved (the operator saw exactly that after
    # deleting a test route). stop_route/1 is a no-op for a route that is not running.
    _ = Blackgate.stop_route(id)

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

          # Its SDI output is already playing somewhere else. Refusing here - and naming the holder - is what
          # keeps this from becoming a route that starts with a silently missing picture: a second engine cannot
          # enable that connector, and it drops the SDI branch without failing the route.
          {:error, {:resource_in_use, claims}} ->
            name = route_name(route_id)

            # One line per claim, so the operator sees every reason at once instead of fixing one and hitting the
            # next on the second attempt.
            Enum.each(claims, fn claim ->
              Blackgate.EventLog.log(
                :warning,
                "output_in_use",
                "Cannot start #{name}: #{claim.label} is in use by #{claim.held_by.route_name}",
                %{
                  route_id: route_id,
                  route_name: name,
                  kind: claim.kind,
                  label: claim.label,
                  held_by_route_id: claim.held_by.route_id,
                  held_by_route_name: claim.held_by.route_name
                }
              )
            end)

            first = hd(claims)

            conn
            |> put_status(:conflict)
            |> json(%{
              error: "SDI being used by #{first.held_by.route_name}",
              message:
                Enum.map_join(claims, "; ", fn claim ->
                  "#{claim.label} is in use by #{claim.held_by.route_name}"
                end),
              conflicts:
                Enum.map(claims, fn claim ->
                  %{
                    kind: claim.kind,
                    label: claim.label,
                    held_by: %{id: claim.held_by.route_id, name: claim.held_by.route_name}
                  }
                end)
            })

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
              |> put_status(:ok)
              |> data(%{status: "switched", active_source: target})

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
    secondary = Blackgate.RouteStatsRegistry.get_secondary_stats(route_id)

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

  defp route_name(route_id) do
    case Db.get_route(route_id) do
      {:ok, route} -> route["name"] || route_id
      _ -> route_id
    end
  end
end
