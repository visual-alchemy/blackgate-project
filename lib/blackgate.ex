defmodule Blackgate do
  @moduledoc false
  require Logger
  alias Blackgate.Db

  @spec start_route(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_route(id) do
    # One serialized gate for every path that admits a route - API start, restart, clone-then-start and the
    # engine's own reconnect. Judging the license and starting the engine under the same lock is what stops a
    # burst of concurrent starts from walking past the route limit.
    with_route_lock(fn ->
      with :ok <- check_output_claims(id),
           {:ok, :allowed} <- Blackgate.License.can_start_route?(id) do
        admit_route(id)
      end
    end)
  end

  # All admission, restart and cutoff decisions share this lock. The requester has to be self(), otherwise
  # :global treats concurrent callers as one owner and the lock stops excluding anything.
  def with_route_lock(fun),
    do: :global.trans({{__MODULE__, :admission}, self()}, fun, [node()])

  defp admit_route(id) do
    # A registered-but-dead tree makes the supervisor answer `{:already_started, pid}` for a route that is not
    # running at all. Clear it before starting, so Start always means start.
    case get_route(id) do
      {:ok, pid} ->
        if route_tree_usable?(pid) do
          {:error, {:already_started, pid}}
        else
          _ = clear_stale_route_entry(id)
          do_start_route(id)
        end

      _ ->
        do_start_route(id)
    end
  end

  defp do_start_route(id) do
    DynamicSupervisor.start_child(
      {:via, PartitionSupervisor, {Blackgate.DynamicSupervisor, id}},
      {Blackgate.RoutesSupervisor, %{id: id}}
    )
  end

  @doc """
  Routes that are actually running, with their destinations.

  Liveness comes from the route registry rather than the stored `status`: the status can read `started` for a
  route whose engine has died, and a route that is running but momentarily mislabelled must still hold its
  listening port. This is the list the output gate judges against.
  """
  @spec running_routes() :: [map()]
  def running_routes do
    routes_holding_outputs(engine_process_route_ids(), &route_including_destinations/1)
  end

  ## The destinations ARE the question: a route record fetched without them makes every route hold nothing and the
  # gate silently allows everything. `Db.get_route/1` omits them by default - caught live, because the holder map
  # came back empty while two engines were running.
  defp route_including_destinations(id), do: Db.get_route(id, true)

  # Route ids read off the live engine processes.
  defp engine_process_route_ids do
    case Blackgate.ProcessMonitor.list_pipeline_processes() do
      list when is_list(list) -> Enum.map(list, & &1[:route_id])
      _ -> []
    end
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The routes that hold an output, judged by their ENGINES.

  A listening port is held by the engine process - it is the one that binds it - so the live engine list is the
  ground truth and the route record is only used to give those entries their real destinations. The registry
  alone is not usable here: it can keep a route whose engine is gone, and measured on this box that made RTMP the
  listed holder of a port with no engine of its own, which then refused the WORKING route on that port.

  A route that only the engine list knows (its record missing) is kept as a bare id: it still counts as running but
  holds no output, because a route with no destinations cannot.
  """
  def routes_holding_outputs(engine_route_ids, lookup) do
    engine_route_ids
    |> Enum.uniq()
    |> Enum.map(fn id ->
      case lookup.(id) do
        {:ok, route} -> route
        _ -> %{"id" => id, "name" => id}
      end
    end)
  end

  # A listening port is judged at START time, not at configuration time: the operator may point a route at a port
  # another route listens on, and the route that is already running keeps it.
  defp check_output_claims(id) do
    case Db.get_route(id) do
      {:ok, route} ->
        # A route with no listening port cannot conflict with anybody, so it is not even asked: the check reads a
        # process listing, and starting a caller-only route has to stay exactly as cheap as it was before any of
        # this existed.
        if Blackgate.OutputClaims.listening_ports_of(route) == [] do
          :ok
        else
          case Blackgate.OutputClaims.claims_of(route, running_routes()) do
            [] -> :ok
            claims -> {:error, {:resource_in_use, claims}}
          end
        end

      other ->
        other
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
    case find_route_tree(id) do
      {:ok, pid} ->
        _ = Supervisor.stop(pid, :normal)

        # Supervisor.stop/2 returns :ok even when the tree was already unusable - measured: a tree that answered
        # `:undefined` for its own RouteHandler child, i.e. the handler was gone while the supervisor stayed
        # registered. Trusting the return value left the route registered, so the next Start answered
        # `{:already_started, pid}` for a route the operator had just stopped. Verify, then clear the entry.
        if route_tree_usable?(pid) do
          Logger.warning(
            "RouteHandler: route #{id} still alive after stop; registry entry left in place"
          )

          :ok
        else
          clear_stale_route_entry(id)
        end

      other ->
        Blackgate.set_route_status(id, "stopped")
        other
    end
  end

  @doc """
  True when this supervisor can still run its route, i.e. it has a live `RouteHandler` child.

  A tree whose handler is `:undefined` cannot run anything, and must neither keep the id registered nor answer
  `already_started` for a route that is not running. Public because the start/stop paths and their tests both judge
  it.
  """
  def route_tree_usable?(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      route_tree_has_live_handler?(pid)
    else
      false
    end
  end

  def route_tree_usable?(_pid), do: false

  defp route_tree_has_live_handler?(pid) do
    case Supervisor.which_children(pid) do
      children when is_list(children) ->
        Enum.any?(children, fn
          {{:route_handler, _}, child, _, _} when is_pid(child) -> Process.alive?(child)
          _ -> false
        end)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  # Only safe when the tree is genuinely unusable: otherwise the id could be removed from under a live route.
  defp clear_stale_route_entry(id) do
    case :syn.lookup(:routes, id) do
      {pid, _} when is_pid(pid) ->
        if route_tree_usable?(pid) do
          :ok
        else
          _ = :syn.unregister(:routes, id)

          case Supervisor.stop(pid, :normal) do
            _ -> :ok
          end
        end

      _ ->
        :ok
    end
  end

  # The registry can be missing a route whose tree is still alive - measured on this box: two routes were
  # reconnecting with live engines and `:syn.lookup` answered `:undefined` for both. A stop that reports
  # `not_found` while the engine keeps streaming is worse than no stop at all, and it is what makes an operator
  # unable to get rid of such a route.
  defp find_route_tree(id) do
    case get_route(id) do
      {:ok, pid} -> {:ok, pid}
      _ -> find_route_tree_by_child(id)
    end
  end

  # The RouteHandler child is named {:route_handler, id}, so the tree around it can be found by name even when
  # nothing registered the route. (Same lookup switch_route_source/2 already relies on.)
  defp find_route_tree_by_child(id) do
    found =
      Blackgate.DynamicSupervisor
      |> PartitionSupervisor.which_children()
      |> Enum.find_value(fn {_partition, tree_pid, _type, _modules} when is_pid(tree_pid) ->
        tree_pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {{:route_handler, ^id}, handler_pid, _, _} when is_pid(handler_pid) -> {:ok, tree_pid}
          _ -> nil
        end)
      end)

    found || {:error, :not_found}
  end

  @spec restart_route(String.t()) :: {:ok, term()} | {:error, term()}
  def restart_route(id) do
    with_route_lock(fn ->
      # Checked BEFORE stopping: changing a destination restarts a running route, and that path used to go straight to
      # start_route/1 with no check at all - so a route could be pointed at an output somebody else already held, get
      # its own engine stopped, and then be refused (or worse, race the holder). Refusing first leaves it running on
      # its previous, valid destination, which is the state the operator can still see and fix.
      #
      # The license is judged while the route is still running, so a restart never consumes a capacity slot it
      # already holds: without that, editing the last route a license allows would stop it and then refuse to
      # start it again.
      with :ok <- check_output_claims(id),
           {:ok, :allowed} <- Blackgate.License.can_start_route?(id) do
        case stop_route(id) do
          {:error, reason} ->
            Logger.warning("Attempt to restart route #{id}, but: #{inspect(reason)}")

          _ ->
            nil
        end

        with {:ok, _pid} <- admit_route(id) do
          {:ok, :restarted}
        end
      end
    end)
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
          _ = Db.update_route(id, %{"active_source" => target})
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

  @doc """
  Path of the stats socket the Rust engines dial.

  Configurable so a development or test node can never bind the same path as a
  running release. A `mix test` run used to bind `/tmp/hydra_unix_sock`, which
  unlinked the live listener's socket and left a dead file behind: every new
  engine then exited with `connect: Connection refused (os error 111)` and its
  route crash-looped while already-connected routes kept running.
  """
  @spec stats_socket_path() :: String.t()
  def stats_socket_path do
    Application.get_env(:blackgate, :stats_socket_path, "/tmp/hydra_unix_sock")
  end
end
