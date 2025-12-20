defmodule BlackgateWeb.BackupController do
  use BlackgateWeb, :controller

  alias Blackgate.Db

  def export(conn, _params) do
    with {:ok, routes} <- Db.get_all_routes(true) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header(
        "content-disposition",
        "inline; filename=\"blackgate_routes_backup.json\""
      )
      |> json(%{data: routes})
    else
      error ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to export routes: #{inspect(error)}"})
    end
  end

  def create_download_link(conn, _params) do
    session_id = UUID.uuid4()

    Cachex.put(Blackgate.Cache, "backup_session:#{session_id}", true, ttl: :timer.minutes(5))

    conn
    |> put_status(:ok)
    |> json(%{download_link: "/backup/#{session_id}/download"})
  end

  def create_backup_download_link(conn, _params) do
    session_id = UUID.uuid4()

    Cachex.put(Blackgate.Cache, "backup_binary_session:#{session_id}", true,
      ttl: :timer.minutes(5)
    )

    conn
    |> put_status(:ok)
    |> json(%{download_link: "/backup/#{session_id}/download_backup"})
  end

  def download(conn, %{"session_id" => session_id}) do
    case Cachex.get(Blackgate.Cache, "backup_session:#{session_id}") do
      {:ok, true} ->
        with {:ok, routes} <- Db.get_all_routes(true) do
          Cachex.del(Blackgate.Cache, "backup_session:#{session_id}")

          json_data = Jason.encode!(routes, pretty: true)

          now = DateTime.utc_now()
          formatted_time = Calendar.strftime(now, "%m-%d-%y-%H:%M:%S")
          filename = "hydra-routes-#{formatted_time}.json"

          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header(
            "content-disposition",
            "attachment; filename=\"#{filename}\""
          )
          |> send_resp(200, json_data)
        else
          error ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to download routes backup: #{inspect(error)}"})
        end

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Invalid or expired download link"})
    end
  end

  def download_backup(conn, %{"session_id" => session_id}) do
    case Cachex.get(Blackgate.Cache, "backup_binary_session:#{session_id}") do
      {:ok, true} ->
        with {:ok, binary_data} <- Db.backup() do
          Cachex.del(Blackgate.Cache, "backup_binary_session:#{session_id}")

          now = DateTime.utc_now()
          formatted_time = Calendar.strftime(now, "%m-%d-%y-%H:%M:%S")
          filename = "hydra-srt-#{formatted_time}.backup"

          conn
          |> put_resp_content_type("application/octet-stream")
          |> put_resp_header(
            "content-disposition",
            "attachment; filename=\"#{filename}\""
          )
          |> send_resp(200, binary_data)
        else
          error ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to download backup: #{inspect(error)}"})
        end

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Invalid or expired download link"})
    end
  end

  def restore(conn, _params) do
    try do
      {:ok, binary_data, _conn} = Plug.Conn.read_body(conn)
      IO.puts("Received binary data of size: #{byte_size(binary_data)} bytes")

      case Db.restore_backup(binary_data) do
        :ok ->
          conn
          |> put_status(:ok)
          |> json(%{message: "Backup restored successfully"})

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "Failed to restore backup: #{inspect(reason)}"})
      end
    rescue
      e ->
        IO.puts("Error processing backup: #{inspect(e)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to process backup: #{inspect(e)}"})
    end
  end

  def import_routes(conn, params) do
    try do
      # The JSON is already parsed by the API pipeline
      # For raw JSON arrays, Phoenix puts it under "_json" key
      # For objects, it's in the params directly
      routes_data = cond do
        # Raw JSON array: params = %{"_json" => [...]}
        is_list(Map.get(params, "_json")) ->
          Map.get(params, "_json")
        
        # Object with data key: params = %{"data" => [...]}
        is_list(Map.get(params, "data")) ->
          Map.get(params, "data")
        
        # Direct params is a list (shouldn't happen with Phoenix but just in case)
        is_list(params) ->
          params
          
        true ->
          nil
      end

      if routes_data == nil do
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid format: expected array of routes or {data: [routes]}"})
      else
        # Import each route
        results = Enum.map(routes_data, fn route_data ->
          import_single_route(route_data)
        end)
        
        successful = Enum.count(results, fn r -> match?({:ok, _}, r) end)
        failed = Enum.count(results, fn r -> match?({:error, _}, r) end)
        
        conn
        |> put_status(:ok)
        |> json(%{
          message: "Import completed",
          imported: successful,
          failed: failed
        })
      end
    rescue
      e ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to import routes: #{inspect(e)}"})
    end
  end

  defp import_single_route(route_data) do
    # Extract route fields (remove id to create new)
    route_params = route_data
      |> Map.drop(["id", "destinations", "inserted_at", "updated_at", "status"])
    
    # Create the route
    case Db.create_route(route_params) do
      {:ok, new_route} ->
        # Import destinations if present
        destinations = Map.get(route_data, "destinations", [])
        Enum.each(destinations, fn dest_data ->
          dest_params = dest_data
            |> Map.drop(["id", "route_id", "inserted_at", "updated_at"])
          
          Db.create_destination(new_route["id"], dest_params)
        end)
        
        {:ok, new_route}
        
      error ->
        error
    end
  end
end
