defmodule Blackgate.LicenseEnforcer do
  @moduledoc "Stops expired/revoked streams independently of network validation."
  use GenServer
  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  def init(_) do
    Process.send_after(self(), :tick, 1_000)
    {:ok, nil}
  end

  def handle_info(:tick, state) do
    enforce()
    Process.send_after(self(), :tick, 1_000)
    {:noreply, state}
  end

  def handle_info(:enforce, state) do
    enforce()
    {:noreply, state}
  end

  def enforce do
    Blackgate.with_route_lock(fn ->
      license = Blackgate.License.get_license()
      limit = if license.expired, do: 0, else: license.max_routes

      Blackgate.running_routes()
      |> Enum.drop(limit)
      |> Enum.each(fn route ->
        Blackgate.stop_route(route.id)

        Blackgate.EventLog.log(
          :warning,
          "license_route_stopped",
          "Route stopped by license enforcement",
          %{route_id: route.id, reason: Map.get(license, :reason) || "Route capacity reduced"}
        )
      end)
    end)
  end
end
