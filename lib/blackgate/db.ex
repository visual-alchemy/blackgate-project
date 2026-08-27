defmodule Blackgate.Db do
  @moduledoc false
  require Logger

  @spec create_route(map, binary | nil) :: {:ok, map} | {:error, any}
  def create_route(data, id \\ nil) when is_map(data) do
    id = if id, do: id, else: UUID.uuid1()
    {destinations, route_data} = Map.pop(data, "destinations", [])

    update = %{
      "id" => id,
      "created_at" => now(),
      "updated_at" => now()
    }

    with :ok <- :khepri.put(["routes", id], Map.merge(route_data, update)),
         :ok <- create_destinations(id, destinations) do
      get_route(id, true)
    else
      other ->
        delete_route(id)
        Logger.error("Failed to create route: #{inspect(other)}")
        normalize_error(other)
    end
  end

  @spec get_route(String.t(), boolean) :: {:ok, map} | {:error, any}
  def get_route(id, include_dest? \\ false) when is_binary(id) do
    case :khepri.get(["routes", id]) do
      {:ok, route} ->
        route =
          if include_dest? do
            destinations_list =
              :khepri.get_many!("routes/#{id}/destinations/*")
              |> Enum.reduce([], fn
                {["routes", _, "destinations", _dest_id], dest}, acc when is_map(dest) ->
                  [dest | acc]

                _, acc ->
                  acc
              end)

            Map.put(route, "destinations", destinations_list)
          else
            route
          end

        {:ok, route}

      other ->
        normalize_get_error(other)
    end
  end

  @spec update_route(String.t(), map) :: {:ok, map} | {:error, any}
  def update_route(id, data) do
    path = ["routes", id]
    now = now()

    case :khepri.get(path) do
      {:ok, route} ->
        new_route = Map.merge(route, Map.put(data, "updated_at", now))
        :ok = :khepri.put(path, new_route)
        :khepri.get(path)

      _ ->
        {:error, :route_not_found}
    end
  end

  @spec delete_route(String.t()) :: [:ok] | [{:error, any}]
  def delete_route(id) when is_binary(id) do
    [:khepri.delete(["routes", id]), :khepri.delete_many("routes/#{id}/destinations/*")]
  end

  @spec create_destination(String.t(), map, binary | nil) :: {:ok, map} | {:error, any}
  def create_destination(route_id, data, id \\ nil) do
    id = if id, do: id, else: UUID.uuid1()

    data =
      Map.merge(data, %{
        "id" => id,
        "route_id" => route_id,
        "created_at" => now(),
        "updated_at" => now()
      })

    with :ok <- :khepri.put(["routes", route_id, "destinations", id], data),
         {:ok, result} <- get_destination(route_id, id) do
      {:ok, result}
    else
      other ->
        Logger.error("Failed to create route: #{inspect(other)}")
        {:error, other}
    end
  end

  @spec get_destination(String.t(), String.t()) :: {:ok, map} | {:error, any}
  def get_destination(route_id, id) when is_binary(route_id) and is_binary(id) do
    ["routes", route_id, "destinations", id]
    |> :khepri.get()
    |> normalize_get_error()
  end

  @spec update_destination(String.t(), String.t(), map) :: {:ok, map} | {:error, any}
  def update_destination(route_id, id, data) do
    path = ["routes", route_id, "destinations", id]
    now = now()

    case :khepri.get(path) do
      {:ok, destination} ->
        new_destination = Map.merge(destination, Map.put(data, "updated_at", now))
        :ok = :khepri.put(path, new_destination)
        :khepri.get(path)

      _ ->
        {:error, :destination_not_found}
    end
  end

  def del_destination(route_id, id) when is_binary(route_id) and is_binary(id) do
    :khepri.delete(["routes", route_id, "destinations", id])
  end

  @spec get_all_routes(boolean, binary) :: {:ok, list(map)} | {:error, any}
  def get_all_routes(with_destinations \\ false, sort_by \\ "created_at") do
    case :khepri.get_many("routes/*") do
      {:ok, routes} ->
        routes =
          routes
          |> Enum.map(fn {_path, route} -> route end)
          |> Enum.filter(&is_map/1)
          |> Enum.map(fn route ->
            if with_destinations do
              route_id = route["id"]

              destinations_list =
                :khepri.get_many!("routes/#{route_id}/destinations/*")
                |> Enum.reduce([], fn
                  {["routes", _, "destinations", _dest_id], dest}, acc when is_map(dest) ->
                    [dest | acc]

                  _, acc ->
                    acc
                end)

              Map.put(route, "destinations", destinations_list)
            else
              route
            end
          end)
          |> Enum.sort_by(fn route -> route[sort_by] end, DateTime)
          |> Enum.reverse()

        {:ok, routes}

      other ->
        Logger.error("Failed to get all routes: #{inspect(other)}")
        other
    end
  end

  def get_all_destinations(route_id) when is_binary(route_id) do
    :khepri.get_many("routes/#{route_id}/destinations/*")
  end

  @spec backup() :: {:ok, binary} | {:error, any}
  def backup() do
    case :khepri.get_many("**") do
      {:ok, data} ->
        binary_data = :erlang.term_to_binary(data)
        {:ok, binary_data}

      error ->
        Logger.error("Failed to create backup: #{inspect(error)}")
        {:error, error}
    end
  end

  @spec restore_backup(binary) :: :ok | {:error, any}
  def restore_backup(binary_data) when is_binary(binary_data) do
    Logger.warning("Restoring backup")

    try do
      data = :erlang.binary_to_term(binary_data)

      :khepri.delete_many("**")

      Enum.each(data, fn {path, value} ->
        :khepri.put(path, value)
      end)

      :ok
    rescue
      e ->
        Logger.error("Failed to restore backup: #{inspect(e)}")
        {:error, e}
    end
  end

  defp create_destinations(_route_id, destinations) when not is_list(destinations), do: :ok

  defp create_destinations(route_id, destinations) do
    Enum.reduce_while(destinations, :ok, fn
      destination, :ok when is_map(destination) ->
        case create_destination(route_id, destination) do
          {:ok, _destination} -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      destination, :ok ->
        {:halt, {:error, {:invalid_destination, destination}}}
    end)
  end

  defp normalize_error({:error, _reason} = error), do: error
  defp normalize_error(reason), do: {:error, reason}

  defp normalize_get_error({:error, {:khepri, :node_not_found, _details}}),
    do: {:error, :not_found}

  defp normalize_get_error({:ok, _value} = result), do: result
  defp normalize_get_error(result), do: normalize_error(result)

  defp now, do: DateTime.utc_now()
end
