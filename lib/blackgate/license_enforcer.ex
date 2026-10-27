defmodule Blackgate.LicenseEnforcer do
  @moduledoc """
  Stops routes the current entitlement does not cover.

  The one-second tick is the reason this exists at all: expiry, revocation, deactivation and a capacity
  downgrade must cut live streams even when nobody touches the API, and the license server may be unreachable
  for weeks while the deadlines it handed out keep passing.
  """
  use GenServer
  require Logger

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :tick, tick_ms())
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    enforce()
    Process.send_after(self(), :tick, tick_ms())
    {:noreply, state}
  end

  # Pushed by Blackgate.License after an activate/deactivate/verify, so a revocation lands on the same tick the
  # state changed instead of up to a second later.
  def handle_info(:enforce, state) do
    enforce()
    {:noreply, state}
  end

  @doc """
  Reconcile running routes against the licensed capacity.

  A reconciler, not a stop-everything: `limit` is what the entitlement currently allows, and only the routes
  beyond it are stopped. That single rule covers expiry (limit 0), a downgrade (10 -> 2) and a route started
  behind the API's back, and it is ordered by route id so the same routes survive a repeated tick.
  """
  def enforce do
    Blackgate.with_route_lock(fn ->
      license = Blackgate.License.get_license()
      limit = if license.expired, do: 0, else: license.max_routes

      Blackgate.running_routes()
      |> Enum.sort_by(& &1["id"])
      |> Enum.drop(limit)
      |> Enum.each(fn route ->
        Blackgate.stop_route(route["id"])

        Blackgate.EventLog.log(
          :warning,
          "license_route_stopped",
          "Route stopped by license enforcement",
          %{route_id: route["id"], reason: license.reason || "Route capacity reduced"}
        )
      end)
    end)
  end

  # 1 s in production: a revoked or expired entitlement must cut live streams promptly. Tests raise it, because
  # they replace whole modules with :meck and a tick landing inside a purged module hangs the purge.
  defp tick_ms, do: Application.get_env(:blackgate, :license_enforcer_tick_ms, 1_000)
end
