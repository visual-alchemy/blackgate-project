defmodule Blackgate do
  @moduledoc false
  require Logger
  alias Blackgate.Db

  @spec start_route(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_route(id) do
    DynamicSupervisor.start_child(
      {:via, PartitionSupervisor, {Blackgate.DynamicSupervisor, id}},
      {Blackgate.RoutesSupervisor, %{id: id}}
    )
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

  The route's `RouteHandler` gen_statem receives a `{:switch_source, target}` cast,
  persists the new `active_source`, and restarts the pipeline against the chosen
  source. Returns `:ok` as soon as the cast is dispatched.
  """
  @spec switch_route_source(String.t(), String.t()) :: :ok | {:error, term()}
  def switch_route_source(id, target) do
    case get_route(id) do
      {:ok, pid} ->
        :gen_statem.cast(pid, {:switch_source, target})

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
