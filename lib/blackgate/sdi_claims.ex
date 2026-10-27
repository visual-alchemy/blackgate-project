defmodule Blackgate.SdiClaims do
  @moduledoc """
  Which running route holds which exclusive resource: an SDI connector, or a listening port.

  The card's connectors are a shared resource, and the failure mode without a gate is bad: a second engine that
  opens a DeckLink device already in use fails to enable video output, warns, and drops that SDI branch while its
  route keeps running - a picture that is simply missing, with nothing to explain it.

  So a route may be CONFIGURED against an output another route uses; the gate is applied when it is started, and
  whoever is already running keeps it. Holding an output therefore means running it, which is the first-come,
  first-served rule, and a stop releases it with no bookkeeping to drift: the caller passes the RUNNING routes in
  (from the route registry, not from the stored `status`, which can say `started` for a route whose engine is
  gone - blocking a free output on a stale label is worse than the conflict this prevents).

  Pure by design: every function here takes the running routes as an argument, so the whole rule is testable
  without a database or a pipeline.
  """

  # Device number -> the connector an operator sees. Ported from the frontend map and verified against the
  # card: the vendor driver enumerates the Duo 2's connectors out of order.
  @device_labels %{0 => "SDI 1", 1 => "SDI 3", 2 => "SDI 2", 3 => "SDI 4"}

  @doc """
  The connector label for a device number, as the operator sees it on the back of the card.
  """
  def device_label(device), do: Map.get(@device_labels, device, "SDI device #{device}")

  @doc "SDI device numbers a route's destinations ask for."
  def devices_of(route) do
    (route["destinations"] || [])
    |> Enum.filter(&(&1["schema"] == "SDI"))
    |> Enum.map(fn
      %{"schema_options" => %{"device_number" => number}} when is_integer(number) -> number
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Devices held by the given running routes: `%{device => %{route_id: id, route_name: name}}`.

  When two running routes somehow hold the same device, the first one wins and the second is ignored - the
  point of this map is to name a holder for the operator, and a duplicate here means the gate was bypassed
  rather than that both can really play to one connector.
  """
  def holders(running_routes) do
    Enum.reduce(running_routes, %{}, fn route, acc ->
      Enum.reduce(devices_of(route), acc, fn device, acc ->
        Map.put_new(acc, device, %{
          route_id: route["id"],
          route_name: route["name"] || route["id"]
        })
      end)
    end)
  end

  @doc """
  The first output this route cannot take, or `nil` when every output it asks for is free.

  The route's own claim is excluded, so restarting a route never conflicts with itself.
  """
  def conflict(route, running_routes) do
    held =
      running_routes
      |> Enum.reject(&(&1["id"] == route["id"]))
      |> holders()

    Enum.find_value(devices_of(route), fn device ->
      case Map.get(held, device) do
        nil -> nil
        holder -> %{device: device, label: device_label(device), held_by: holder}
      end
    end)
  end

  # ── Listening ports ────────────────────────────────────────────────────────────────────────────────
  #
  # The same class of failure as the card, one layer down: two routes that both LISTEN on one local port cannot
  # both bind it, and the engine that loses fails to start with nothing explaining why. Only listeners are a
  # claim - a caller dials out and binds nothing.

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
  Every exclusive resource this route cannot take, as a list of maps.

  Each conflict carries a `kind` (`:sdi` or `:port`), a `label` for the operator ("SDI 1", "port 17001") and the
  holder. The route's own claims are excluded, so restarting a route never conflicts with itself.
  """
  def claims_of(route, running_routes) do
    others = Enum.reject(running_routes, &(&1["id"] == route["id"]))

    sdi =
      case conflict(route, running_routes) do
        nil -> []
        conflict -> [Map.put(conflict, :kind, :sdi)]
      end

    held_ports = port_holders(others)

    ports =
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

    sdi ++ ports
  end

  @doc """
  True when this route's listener port is already taken by another running route.

  Used to keep the form honest: a port is a hard bind, so the operator should see the conflict while typing it
  rather than after pressing Start.
  """
  def port_conflict?(route, running_routes) do
    Enum.any?(claims_of(route, running_routes), &(&1.kind == :port))
  end

  @doc """
  One sentence per claim the route cannot take, in the wording the dashboard already recognises:
  `"SDI 1 is in use by <route>; port 9101 is in use by <route>"`.

  Built here because TWO callers need the same sentence — the Start refusal and the restart that a route or
  destination edit triggers — and a second copy of the phrasing would drift out of the frontend's pattern.
  """
  def describe_conflicts(claims) do
    Enum.map_join(claims, "; ", fn claim ->
      "#{claim[:label] || claim[:kind]} is in use by #{claim[:held_by][:route_name]}"
    end)
  end
end
