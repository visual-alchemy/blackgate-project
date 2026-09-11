defmodule BlackgateWeb.SystemController do
  use BlackgateWeb, :controller

  alias Blackgate.Db
  alias Blackgate.ProcessMonitor
  alias Blackgate.Helpers
  alias Blackgate.SystemControl

  def status(conn, _params), do: json(conn, %{data: SystemControl.status()})

  def report(conn, _params) do
    filename =
      "blackgate-system-report-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")}.txt"

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
    |> send_resp(200, SystemControl.report())
  end

  def perform_action(conn, %{"action" => action}) do
    case SystemControl.action(action) do
      {:ok, message} ->
        conn
        |> put_status(:accepted)
        |> json(%{message: message, action: action})

      {:error, message} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "System action unavailable: #{message}"})
    end
  end

  def list_pipelines(conn, _params) do
    pipelines = ProcessMonitor.list_pipeline_processes() |> add_route_names()
    json(conn, pipelines)
  end

  def list_pipelines_detailed(conn, _params) do
    pipelines = ProcessMonitor.list_pipeline_processes_detailed() |> add_route_names()
    json(conn, pipelines)
  end

  def kill_pipeline(conn, %{"pid" => pid_str}) do
    with {pid, _} <- Integer.parse(pid_str),
         {_, 0} <- Helpers.sys_kill(pid_str) do
      json(conn, %{success: true, message: "Process #{pid} killed successfully"})
    else
      :error ->
        conn
        |> put_status(400)
        |> json(%{error: "Invalid PID format"})

      {error, _} ->
        conn
        |> put_status(500)
        |> json(%{error: "Failed to kill process: #{inspect(error)}"})
    end
  end

  defp add_route_names(pipelines) when is_list(pipelines) do
    route_names =
      case Db.get_all_routes(false) do
        {:ok, routes} ->
          Map.new(routes, fn route ->
            route_id = route["id"]
            {route_id, route["name"] || route_id}
          end)

        _ ->
          %{}
      end

    Enum.map(pipelines, fn pipeline ->
      route_id = Map.get(pipeline, :route_id)
      Map.put(pipeline, :route_name, Map.get(route_names, route_id))
    end)
  end

  defp add_route_names(other), do: other
end
