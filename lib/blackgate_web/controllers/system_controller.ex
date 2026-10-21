defmodule BlackgateWeb.SystemController do
  use BlackgateWeb, :controller

  alias Blackgate.ProcessMonitor
  alias Blackgate.Helpers
  alias Blackgate.SystemControl

  def list_pipelines(conn, _params) do
    pipelines = ProcessMonitor.list_pipeline_processes()
    json(conn, pipelines)
  end

  def list_pipelines_detailed(conn, _params) do
    pipelines = ProcessMonitor.list_pipeline_processes_detailed()
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

  # Host view for Settings > System. Read-only: the restart/reboot/deploy actions need the
  # privileged helper and the systemd unit a packaged appliance installs, and land in a later phase.
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

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9A-Za-z]/, "")
  end
end
