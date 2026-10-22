defmodule Blackgate.SdiClaims do
  @moduledoc """
  Which running route holds which SDI output.

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
end
