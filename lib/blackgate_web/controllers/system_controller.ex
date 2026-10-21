defmodule BlackgateWeb.SystemController do
  use BlackgateWeb, :controller

  alias Blackgate.Db
  alias Blackgate.ProcessMonitor
  alias Blackgate.Helpers
  alias Blackgate.SystemControl
  alias Blackgate.SystemUpdates

  def list_pipelines(conn, _params) do
    pipelines = ProcessMonitor.list_pipeline_processes()
    json(conn, pipelines)
  end

  def list_pipelines_detailed(conn, _params) do
    pipelines =
      ProcessMonitor.list_pipeline_processes_detailed()
      |> add_route_names()

    json(conn, pipelines)
  end

  # Each engine process carries its route id as its only argument, so the pipeline list can say WHICH
  # route an engine belongs to instead of showing a bare UUID. A route whose lookup misses keeps the id.
  @doc false
  def add_route_names(pipelines) when is_list(pipelines) do
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

  def add_route_names(other), do: other

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

  # ---------------------------------------------------------------------------------------------
  # Settings > System: the host view, the privileged actions and update packages.
  #
  # Actions are never executed here — they are handed to the allowlisted root helper through
  # Blackgate.SystemControl, which schedules them as delayed systemd units so they can still be
  # cancelled. Everything the dashboard shows comes from the host and the deployment root, not from
  # configuration.
  # ---------------------------------------------------------------------------------------------

  def status(conn, _params) do
    json(conn, SystemControl.status())
  end

  def report(conn, _params) do
    filename = "blackgate-system-report-#{timestamp()}.txt"

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, SystemControl.report())
  end

  def perform_action(conn, %{"action" => action} = params) do
    # `unit` for cancel, `version` for deploy: either way a single allowlisted argument.
    case SystemControl.perform_action(action, params["unit"] || params["version"]) do
      {:ok, result} ->
        conn
        |> put_status(:accepted)
        |> json(result)

      {:error, message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: message})
    end
  end

  def updates(conn, _params) do
    json(conn, SystemUpdates.summary())
  end

  # The package body is streamed straight to disk: this route sits in the :api_no_parse scope, whose
  # content type (*/*, and the client sends application/octet-stream) makes Plug.Parsers pass the
  # body through untouched.
  def upload_update(conn, params) do
    filename = params["filename"] || header_filename(conn)

    with {:ok, version, part_path} <- SystemUpdates.prepare_upload(filename) do
      case SystemUpdates.store_body(conn, part_path) do
        {:ok, _conn, bytes} ->
          case SystemUpdates.commit_upload(version, part_path) do
            {:ok, package} ->
              conn
              |> put_status(:created)
              |> json(Map.put(package, :bytes, bytes))

            {:error, message} ->
              SystemUpdates.discard_upload(part_path)

              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: message})
          end

        {:error, message} ->
          SystemUpdates.discard_upload(part_path)

          conn
          |> put_status(:bad_request)
          |> json(%{error: message})
      end
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})
    end
  end

  def deploy_update(conn, %{"version" => version}) do
    case SystemUpdates.deploy(version) do
      {:ok, result} ->
        conn
        |> put_status(:accepted)
        |> json(result)

      {:error, message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: message})
    end
  end

  defp header_filename(conn) do
    conn
    |> get_req_header("x-filename")
    |> List.first()
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9A-Za-z]/, "")
  end
end
