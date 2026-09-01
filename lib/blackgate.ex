defmodule Blackgate do
  @moduledoc false
  require Logger
  alias Blackgate.Db

  @spec start_route(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_route(id) do
    case DynamicSupervisor.start_child(
           {:via, PartitionSupervisor, {Blackgate.DynamicSupervisor, id}},
           {Blackgate.RoutesSupervisor, %{id: id}}
         ) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @spec get_route(String.t()) :: {:ok, pid()} | {:error, term()}
  def get_route(id) do
    case :syn.lookup(:routes, id) do
      {pid, _} when is_pid(pid) -> {:ok, pid}
      :undefined -> {:error, :not_found}
    end
  end

  @spec stop_route(String.t()) :: :ok | {:error, term()}
  def stop_route(id) do
    case get_route(id) do
      {:ok, pid} ->
        Supervisor.stop(pid, :normal)

      other ->
        Blackgate.set_route_status(id, "stopped")
        other
    end
  end

  @spec restart_route(String.t()) :: {:ok, term()} | {:error, term()}
  def restart_route(id) do
    case stop_route(id) do
      {:error, reason} ->
        Logger.warning("Attempt to restart route #{id}, but: #{inspect(reason)}")

      _ ->
        nil
    end

    with {:ok, _pid} <- start_route(id) do
      {:ok, :restarted}
    end
  end

  @doc """
  Manually switches a running route's active SRT source to `target`.

  RouteHandler dispatches native switch or restart work. Persisted
  `active_source` changes only after native acknowledgement or successful
  replacement-pipeline startup. Returns `:ok` when request is accepted.
  """
  @spec switch_route_source(String.t(), String.t()) :: :ok | {:error, term()}
  def switch_route_source(id, target) do
    case get_route(id) do
      {:ok, sup_pid} ->
        # find the RouteHandler child pid from the supervisor
        handler_pid =
          sup_pid
          |> Supervisor.which_children()
          |> Enum.find_value(fn
            {{:route_handler, ^id}, pid, _, _} -> pid
            _ -> nil
          end)

        if handler_pid == nil do
          Logger.error("RouteHandler: pid not found for route #{id}")
          {:error, :handler_not_found}
        else
          :gen_statem.cast(handler_pid, {:switch_source, target})
        end

      other ->
        other
    end
  end

  @spec set_route_status(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_route_status(id, status) do
    with {:ok, route} <- Db.update_route(id, %{"status" => status}) do
      {:ok, route}
    end
  end

  @spec set_route_error(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def set_route_error(id, error_message) do
    with {:ok, route} <- Db.update_route(id, %{"error_message" => error_message}) do
      {:ok, route}
    end
  end
end
