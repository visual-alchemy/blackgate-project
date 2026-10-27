defmodule Blackgate.LicenseEnforcer do
  @moduledoc """
  Stops routes the licence no longer covers.

  `Blackgate.start_route/1` judges the licence when a route is STARTED, and that is all it can do. A key that
  expires, a trial that runs out, or a licence deactivated or replaced by a smaller plan leaves the engines that
  were started under the old terms running: measured on the C-engine line, a deactivated licence left five engines
  streaming on an appliance whose dashboard said the licence permitted none. This pass closes that gap - it reads
  the capacity the licence allows right now and stops the routes above it.

  WHICH routes go is decided the same way on every pass (sorted by route id, the first `capacity` are kept): a pass
  that picked a different set each tick would cut a different stream every tick while the operator watched it. The
  judgment and the stops happen under the route-admission lock, so a pass cannot interleave with a start that is
  judging the same licence.

  An unreadable licence state fails OPEN here - nothing is stopped - because taking every stream down over a number
  this module could not read is worse than leaving a route running that the operator can stop by hand. Strictness
  belongs to the admission gate, which fails closed: no start is admitted without a licence.

  The tick is 10 s rather than the C-era engine's 1 s because every pass reads the live engine set, which costs a
  process listing. A licence change that matters is measured in days, and the immediate case - the operator
  activating, deactivating or re-syncing a key - does not wait for a tick: `Blackgate.License` asks for a pass as
  soon as its state changes.
  """
  use GenServer
  require Logger

  alias Blackgate.{Db, EventLog, License}

  @tick_ms 10_000

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @doc """
  One enforcement pass: stop every running route above the licence's capacity.

  Returns `{:ok, stopped_route_ids}` in the order they were stopped, or `:unreadable` when the licence state could
  not be read at all - in which case nothing was touched.
  """
  @spec enforce() :: {:ok, [String.t()]} | :unreadable
  def enforce do
    Blackgate.with_route_lock(fn ->
      case license() do
        :unreadable ->
          :unreadable

        license ->
          capacity = License.capacity_of(license)
          running = Blackgate.running_route_ids() |> Enum.uniq() |> Enum.sort()

          stopped =
            running
            |> Enum.drop(capacity)
            |> Enum.map(&stop_uncovered_route(&1, license, capacity, length(running)))

          {:ok, stopped}
      end
    end)
  end

  @doc "Ask for a pass soon. Used by `Blackgate.License` when the licence itself changes."
  @spec enforce_soon() :: :ok
  def enforce_soon do
    GenServer.cast(__MODULE__, :enforce)
  end

  # ─── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_args) do
    {:ok, %{readable: true}, {:continue, :first_tick}}
  end

  @impl true
  def handle_continue(:first_tick, state) do
    {:noreply, schedule_tick(state)}
  end

  @impl true
  def handle_cast(:enforce, state) do
    {:noreply, run_pass(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    {:noreply, state |> run_pass() |> schedule_tick()}
  end

  defp schedule_tick(state) do
    Process.send_after(self(), :tick, @tick_ms)
    state
  end

  defp run_pass(state) do
    case enforce() do
      {:ok, _stopped} -> %{state | readable: true}
      :unreadable -> report_unreadable(state)
    end
  end

  @spec report_unreadable(map()) :: map()
  defp report_unreadable(%{readable: false} = state), do: state

  # Once per transition, not once per tick: a state that stays unreadable for ten minutes would otherwise write an
  # event every ten seconds and bury everything else on the Events tab.
  defp report_unreadable(state) do
    EventLog.log(
      :critical,
      "license_unreadable",
      "Could not read the licence state; no routes were stopped",
      %{}
    )

    %{state | readable: false}
  end

  defp license do
    License.get_license()
  rescue
    _ -> :unreadable
  end

  defp stop_uncovered_route(route_id, license, capacity, running_count) do
    _ = Blackgate.stop_route(route_id)

    EventLog.log(
      :warning,
      "license_route_stopped",
      "Route stopped: #{sentence(license, capacity)}",
      %{
        route_id: route_id,
        route_name: route_name(route_id),
        capacity: capacity,
        running_routes: running_count
      }
    )

    route_id
  end

  # The sentence names the licence, not just the rule: the operator reading the Events tab has to know whether to
  # buy a bigger licence, fix a key, or simply start fewer routes.
  defp sentence(%{expired: true}, _capacity), do: "the licence has expired"

  defp sentence(%{status: :unlicensed}, _capacity), do: "there is no valid licence"

  defp sentence(%{status: :trial}, capacity),
    do: "the trial covers #{capacity} #{plural(capacity)}"

  defp sentence(%{status: :licensed, max_routes: n}, _capacity),
    do: "the licence covers #{n} #{plural(n)}"

  defp sentence(_license, capacity), do: "the licence covers #{capacity} #{plural(capacity)}"

  defp plural(1), do: "route"
  defp plural(_), do: "routes"

  defp route_name(route_id) do
    case Db.get_route(route_id) do
      {:ok, route} -> route["name"] || route_id
      _ -> route_id
    end
  end
end
