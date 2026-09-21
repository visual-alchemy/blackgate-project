defmodule Blackgate.Db do
  @moduledoc false
  require Logger
  @sdi_not_supported_message "SDI output not supported on Blackgate Lite"

  @spec create_route(map, binary | nil) :: {:ok, map} | {:error, any}
  def create_route(data, id \\ nil) when is_map(data) do
    with :ok <- validate_no_sdi(data) do
      :global.trans({{__MODULE__, :route_creation}, self()}, fn ->
        create_route_with_license(data, id)
      end)
    end
  end

  defp create_route_with_license(data, id) do
    id = if id, do: id, else: UUID.uuid1()

    update = %{
      "id" => id,
      "created_at" => now(),
      "updated_at" => now()
    }

    with {:ok, :allowed} <- Blackgate.License.can_create_route?(),
         :ok <- :khepri.put(["routes", id], Map.merge(data, update)),
         {:ok, result} <- get_route(id) do
      {:ok, result}
    else
      {:error, _reason} = error ->
        error

      other ->
        Logger.error("Failed to create route: #{inspect(other)}")
        {:error, other}
    end
  end

  @spec get_route(String.t(), boolean) :: {:ok, map | nil} | {:error, any}
  def get_route(id, include_dest? \\ false) when is_binary(id) do
    case :khepri.get(["routes", id]) do
      {:error, {:khepri, :node_not_found, _info}} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}

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
    end
  end

  @spec update_route(String.t(), map) :: {:ok, map} | {:error, any}
  def update_route(id, data) do
    with :ok <- validate_no_sdi(data) do
      path = ["routes", id]
      now = now()

      :khepri.transaction(fn ->
        case :khepri_tx.get(path) do
          {:ok, route} ->
            new_route = Map.merge(route, Map.put(data, "updated_at", now))

            :ok = :khepri_tx.put(path, new_route)
            :khepri_tx.get(path)

          _ ->
            {:error, :route_not_found}
        end
      end)
      |> case do
        {:ok, result} -> result
        other -> {:error, inspect(other)}
      end
    end
  end

  @spec delete_route(String.t()) :: [:ok] | [{:error, any}]
  def delete_route(id) when is_binary(id) do
    [:khepri.delete(["routes", id]), :khepri.delete_many("routes/#{id}/destinations/*")]
  end

  @spec create_destination(String.t(), map, binary | nil) :: {:ok, map} | {:error, any}
  def create_destination(route_id, data, id \\ nil) do
    with :ok <- validate_no_sdi(data) do
      create_destination_allowed(route_id, data, id)
    end
  end

  defp create_destination_allowed(route_id, data, id) do
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
        Logger.error("Failed to create destination: #{inspect(other)}")
        {:error, other}
    end
  end

  @spec get_destination(String.t(), String.t()) :: {:ok, map} | {:error, any}
  def get_destination(route_id, id) when is_binary(route_id) and is_binary(id) do
    :khepri.get(["routes", route_id, "destinations", id])
  end

  @spec update_destination(String.t(), String.t(), map) :: {:ok, map} | {:error, any}
  def update_destination(route_id, id, data) do
    with :ok <- validate_no_sdi(data) do
      path = ["routes", route_id, "destinations", id]
      now = now()

      :khepri.transaction(fn ->
        case :khepri_tx.get(path) do
          {:ok, destination} ->
            new_destination = Map.merge(destination, Map.put(data, "updated_at", now))

            :ok = :khepri_tx.put(path, new_destination)
            :khepri_tx.get(path)

          _ ->
            {:error, :destination_not_found}
        end
      end)
      |> case do
        {:ok, result} -> result
        other -> {:error, inspect(other)}
      end
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

  @network_interface_aliases_path ["network", "interface_aliases"]

  @spec get_network_interface_aliases() ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, any}
  def get_network_interface_aliases do
    case :khepri.get(@network_interface_aliases_path) do
      {:ok, aliases} when is_map(aliases) -> {:ok, aliases}
      {:error, {:khepri, :node_not_found, _info}} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
      _other -> {:ok, %{}}
    end
  end

  @spec set_network_interface_alias(String.t(), String.t() | nil) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, any}
  def set_network_interface_alias(mac, alias)
      when is_binary(mac) and (is_binary(alias) or is_nil(alias)) do
    with {:ok, aliases} <- get_network_interface_aliases() do
      aliases =
        case alias do
          nil -> Map.delete(aliases, mac)
          value -> Map.put(aliases, mac, value)
        end

      case :khepri.put(@network_interface_aliases_path, aliases) do
        :ok -> {:ok, aliases}
        other -> {:error, other}
      end
    end
  end

  @spec backup() :: {:ok, binary} | {:error, any}
  def backup() do
    case :khepri.get_many("**") do
      {:ok, data} ->
        binary_data =
          :erlang.term_to_binary(Map.filter(data, fn {path, _} -> backup_path?(path) end))

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
      data = :erlang.binary_to_term(binary_data, [:safe])
      if not is_map(data), do: raise(ArgumentError, "Invalid backup format")
      allowed = Map.filter(data, fn {path, _} -> backup_path?(path) end)

      if map_size(allowed) == 0,
        do: raise(ArgumentError, "Backup contains no supported configuration")

      if not Enum.all?(allowed, fn {_, value} -> is_map(value) end),
        do: raise(ArgumentError, "Invalid configuration values")

      if Enum.any?(allowed, fn {_, value} -> has_sdi_destination?(value) end),
        do: raise(ArgumentError, @sdi_not_supported_message)

      # Share creation lock with create/clone/import. Never import protected
      # namespaces, even when reading a legacy full-database backup.
      :global.trans({{__MODULE__, :route_creation}, self()}, fn ->
        license = Blackgate.License.get_license()
        route_count = Enum.count(allowed, fn {path, _} -> match?(["routes", _], path) end)

        if license.status == :trial and route_count > 2 do
          {:error, :trial_route_limit}
        else
          Blackgate.with_route_lock(fn ->
            Enum.each(Blackgate.running_routes(), &Blackgate.stop_route(&1.id))

            normalized =
              Map.new(allowed, fn
                {["routes", id] = path, value} ->
                  {path, Map.merge(value, %{"id" => id, "status" => "stopped"})}

                entry ->
                  entry
              end)

            :khepri.transaction(fn ->
              :ok = :khepri_tx.delete_many("routes/**")
              :maps.fold(fn path, value, :ok -> :khepri_tx.put(path, value) end, :ok, normalized)
            end)
            |> case do
              {:ok, :ok} -> :ok
              other -> other
            end
          end)
        end
      end)
    rescue
      e ->
        Logger.error("Failed to restore backup: #{inspect(e)}")
        {:error, e}
    end
  end

  defp backup_path?(["routes", id]) when is_binary(id), do: true

  defp backup_path?(["routes", id, "destinations", dest]) when is_binary(id) and is_binary(dest),
    do: true

  defp backup_path?(["network", "interface_aliases"]), do: true
  defp backup_path?(_), do: false

  defp now, do: DateTime.utc_now()

  defp validate_no_sdi(data) do
    if has_sdi_destination?(data), do: {:error, @sdi_not_supported_message}, else: :ok
  end

  defp has_sdi_destination?(data) when is_map(data) do
    case Map.get(data, "destinations", Map.get(data, :destinations)) do
      destinations when is_list(destinations) -> Enum.any?(destinations, &sdi_destination?/1)
      _ -> sdi_destination?(data)
    end
  end

  defp has_sdi_destination?(_data), do: false

  defp sdi_destination?(destination) when is_map(destination) do
    Map.get(destination, "schema", Map.get(destination, :schema)) == "SDI"
  end

  defp sdi_destination?(_destination), do: false
end
