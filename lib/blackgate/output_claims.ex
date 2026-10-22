defmodule Blackgate.OutputClaims do
  @moduledoc """
  Which running route holds which listening port.

  Two routes that both LISTEN on one local port cannot both bind it, and the engine that loses fails to start
  with nothing explaining why. Only listeners are a claim - a caller dials out and binds nothing.

  So a route may be CONFIGURED against a port another route listens on; the gate is applied when it is started,
  and whoever is already running keeps it. Holding a port therefore means running it, which is the first-come,
  first-served rule, and a stop releases it with no bookkeeping to drift: the caller passes the RUNNING routes in
  (from the route registry, not from the stored `status`, which can say `started` for a route whose engine is
  gone - blocking a free port on a stale label is worse than the conflict this prevents).

  Pure by design: every function here takes the running routes as an argument, so the whole rule is testable
  without a database or a pipeline.
  """

  @doc "Local ports this route wants to listen on."
  def listening_ports_of(route) do
    if Map.get(route, "schema") == "SRT" do
      opts = route["schema_options"] || %{}

      if Map.get(opts, "mode") == "listener" do
        case Map.get(opts, "localport") || Map.get(opts, "port") do
          port when is_integer(port) ->
            [port]

          port when is_binary(port) ->
            case Integer.parse(port) do
              {number, ""} -> [number]
              _ -> []
            end

          _ ->
            []
        end
      else
        []
      end
    else
      []
    end
  end

  @doc """
  Ports held by the given running routes: `%{port => %{route_id: id, route_name: name}}`.
  """
  def port_holders(running_routes) do
    Enum.reduce(running_routes, %{}, fn route, acc ->
      Enum.reduce(listening_ports_of(route), acc, fn port, acc ->
        Map.put_new(acc, port, %{
          route_id: route["id"],
          route_name: route["name"] || route["id"]
        })
      end)
    end)
  end

  @doc """
  Every listening port this route cannot take, as a list of maps.

  Each conflict carries a `kind` (`:port`), a `label` for the operator ("port 17001") and the holder. The route's
  own claims are excluded, so restarting a route never conflicts with itself.
  """
  def claims_of(route, running_routes) do
    others = Enum.reject(running_routes, &(&1["id"] == route["id"]))
    held_ports = port_holders(others)

    route
    |> listening_ports_of()
    |> Enum.flat_map(fn port ->
      case Map.get(held_ports, port) do
        nil ->
          []

        holder ->
          [%{kind: :port, port: port, label: "port #{port}", held_by: holder}]
      end
    end)
  end

  @doc """
  True when this route's listener port is already taken by another running route.

  Used to keep the form honest: a port is a hard bind, so the operator should see the conflict while typing it
  rather than after pressing Start.
  """
  def port_conflict?(route, running_routes) do
    Enum.any?(claims_of(route, running_routes), &(&1.kind == :port))
  end
end
