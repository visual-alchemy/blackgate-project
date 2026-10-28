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
      conn
      |> put_status(:created)
      |> data(Map.merge(route, maybe_restart(route_id, was_running)))
    end
  end

  def show(conn, %{"dest_id" => id, "route_id" => route_id}) do
    {:ok, route} = Db.get_destination(route_id, id)
    data(conn, route)
  end

  def update(conn, %{"dest_id" => id, "route_id" => route_id, "destination" => dest_params}) do
    was_running = route_is_running?(route_id)

    with {:ok, route} <- Db.update_destination(route_id, id, dest_params) do
      data(conn, Map.merge(route, maybe_restart(route_id, was_running)))
    end
  end

  def delete(conn, %{"dest_id" => id, "route_id" => route_id}) do
    was_running = route_is_running?(route_id)

    with :ok <- Db.del_destination(route_id, id) do
      conn
      |> put_status(:ok)
      |> json(%{data: Map.merge(%{deleted: true}, maybe_restart(route_id, was_running))})
    end
  end

  # A destination edit on a running route restarts it, and that restart can be REFUSED - a listening port or an SDI
  # connector another route holds. Reporting `restarted: was_running` told the operator the change was live while the
  # engine stayed down on its previous destination, so the refusal is reported beside the change and the response
  # never claims more than happened.
  defp maybe_restart(_route_id, false), do: %{"restarted" => false}

  defp maybe_restart(route_id, true) do
    case Blackgate.restart_route(route_id) do
      {:ok, _} ->
        %{"restarted" => true}

      :ok ->
        %{"restarted" => true}

      {:error, reason} ->
        %{"restarted" => false, "restart_error" => describe_restart_error(reason)}
    end
  end

  # The operator cannot act on an Elixir tuple. Name what holds the resource, in the same wording the Start button
  # already uses ("SDI 1 is in use by <route>"), so the form's own conflict handling recognises it.
  defp describe_restart_error({:resource_in_use, claims}),
    do: Blackgate.SdiClaims.describe_conflicts(claims)

  # The licence already wrote this sentence for an operator ("Route limit reached (10)..."), so it is passed
  # through: the alternative is a tuple they cannot act on.
  defp describe_restart_error({:license, reason}), do: reason

  defp describe_restart_error(:not_found), do: "this route is no longer registered"
  defp describe_restart_error(reason), do: inspect(reason)

  defp route_is_running?(route_id) do
    case Blackgate.get_route(route_id) do
      {:ok, _pid} -> true
      _ -> false
    end
  end

  defp data(conn, data), do: json(conn, %{data: data})
end
