defmodule BlackgateWeb.DestinationController do
  use BlackgateWeb, :controller

  alias Blackgate.Db

  action_fallback BlackgateWeb.FallbackController

  def index(conn, %{"route_id" => route_id}) do
    {:ok, destinations} = Db.get_all_destinations(route_id)

    destinations =
      Enum.reduce(destinations, [], fn {["destinations", id], route}, acc ->
        [Map.put(route, "id", id) | acc]
      end)

    data(conn, destinations)
  end

  def create(conn, %{"destination" => dest_params, "route_id" => route_id}) do
    was_running = route_is_running?(route_id)

    with {:ok, route} <- Db.create_destination(route_id, dest_params) do
      if was_running do
        Blackgate.restart_route(route_id)
      end

      conn
      |> put_status(:created)
      |> data(Map.put(route, "restarted", was_running))
    end
  end

  def show(conn, %{"dest_id" => id, "route_id" => route_id}) do
    {:ok, route} = Db.get_destination(route_id, id)
    data(conn, route)
  end

  def update(conn, %{"dest_id" => id, "route_id" => route_id, "destination" => dest_params}) do
    was_running = route_is_running?(route_id)

    with {:ok, route} <- Db.update_destination(route_id, id, dest_params) do
      if was_running do
        Blackgate.restart_route(route_id)
      end

      data(conn, Map.put(route, "restarted", was_running))
    end
  end

  def delete(conn, %{"dest_id" => id, "route_id" => route_id}) do
    was_running = route_is_running?(route_id)

    with :ok <- Db.del_destination(route_id, id) do
      if was_running do
        Blackgate.restart_route(route_id)
      end

      conn
      |> put_status(:ok)
      |> json(%{data: %{deleted: true, restarted: was_running}})
    end
  end

  defp route_is_running?(route_id) do
    case Blackgate.get_route(route_id) do
      {:ok, _pid} -> true
      _ -> false
    end
  end

  defp data(conn, data), do: json(conn, %{data: data})
end

