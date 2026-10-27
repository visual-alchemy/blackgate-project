defmodule BlackgateWeb.DestinationController do
  use BlackgateWeb, :controller

  alias Blackgate.Db

  action_fallback BlackgateWeb.FallbackController

  def index(conn, %{"route_id" => route_id}) do
    {:ok, destinations} = Db.get_all_destinations(route_id)

    destinations =
      Enum.reduce(destinations, [], fn
        {["routes", ^route_id, "destinations", id], destination}, acc ->
          [Map.put(destination, "id", id) | acc]

        _unexpected, acc ->
          acc
      end)

    data(conn, destinations)
  end

  def create(conn, %{"destination" => dest_params, "route_id" => route_id}) do
    was_running = route_is_running?(route_id)

    with {:ok, route} <- Db.create_destination(route_id, dest_params) do
      restart = maybe_restart(route_id, was_running)

      conn
      |> put_status(:created)
      |> data(Map.merge(route, restart))
    end
  end

  def show(conn, %{"dest_id" => id, "route_id" => route_id}) do
    {:ok, route} = Db.get_destination(route_id, id)
    data(conn, route)
  end

  def update(conn, %{"dest_id" => id, "route_id" => route_id, "destination" => dest_params}) do
    was_running = route_is_running?(route_id)

    with {:ok, route} <- Db.update_destination(route_id, id, dest_params) do
      restart = maybe_restart(route_id, was_running)
      data(conn, Map.merge(route, restart))
    end
  end

  def delete(conn, %{"dest_id" => id, "route_id" => route_id}) do
    was_running = route_is_running?(route_id)

    with :ok <- Db.del_destination(route_id, id) do
      restart = maybe_restart(route_id, was_running)

      conn
      |> put_status(:ok)
      |> json(%{data: Map.merge(%{deleted: true}, restart)})
    end
  end

  ## A destination edit on a running route restarts it. That restart can be REFUSED - a held output port, or a
  # licence that no longer covers the route - and reporting `restarted: true` regardless told the operator the
  # change was live when the route was still streaming on its previous destination. The refusal is reported
  # beside the change, so the response never claims more than happened.
  defp maybe_restart(_route_id, false), do: %{"restarted" => false}

  defp maybe_restart(route_id, true) do
    case Blackgate.restart_route(route_id) do
      {:ok, _} -> %{"restarted" => true}
      :ok -> %{"restarted" => true}
      {:error, reason} -> %{"restarted" => false, "restart_error" => describe(reason)}
    end
  end

  defp describe({:license, reason}), do: reason
  defp describe(reason), do: inspect(reason)

  defp route_is_running?(route_id) do
    case Blackgate.get_route(route_id) do
      {:ok, _pid} -> true
      _ -> false
    end
  end

  defp data(conn, data), do: json(conn, %{data: data})
end
