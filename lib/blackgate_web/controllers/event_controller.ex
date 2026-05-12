defmodule BlackgateWeb.EventController do
  use BlackgateWeb, :controller

  alias Blackgate.EventLog

  def index(conn, params) do
    opts = []

    opts =
      case params["severity"] do
        s when s in ["info", "warning", "critical"] -> [{:severity, String.to_atom(s)} | opts]
        _ -> opts
      end

    opts =
      case params["route_id"] do
        nil -> opts
        "" -> opts
        route_id -> [{:route_id, route_id} | opts]
      end

    opts =
      case params["type"] do
        nil -> opts
        "" -> opts
        type -> [{:type, type} | opts]
      end

    opts =
      case params["limit"] do
        nil -> [{:limit, 100} | opts]
        limit -> [{:limit, String.to_integer(limit)} | opts]
      end

    events = EventLog.get_events(opts)

    # Convert atoms to strings for JSON serialization
    serialized =
      Enum.map(events, fn event ->
        %{
          id: event.id,
          severity: Atom.to_string(event.severity),
          type: event.type,
          message: event.message,
          metadata: event.metadata,
          timestamp: DateTime.to_iso8601(event.timestamp)
        }
      end)

    json(conn, %{data: serialized})
  end

  def counts(conn, _params) do
    counts = EventLog.counts()

    json(conn, %{
      data: %{
        info: counts.info,
        warning: counts.warning,
        critical: counts.critical,
        total: counts.info + counts.warning + counts.critical
      }
    })
  end

  def clear(conn, _params) do
    EventLog.clear()
    json(conn, %{message: "Events cleared"})
  end
end
