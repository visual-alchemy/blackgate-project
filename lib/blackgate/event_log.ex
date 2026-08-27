defmodule Blackgate.EventLog do
  @moduledoc """
  In-memory event log for system events (route start/stop, SDI failures, connection changes).
  Stores the last N events in ETS as a ring buffer. Events are ephemeral — they don't
  survive restarts. For persistent history, use external logging/metrics.
  """

  use GenServer
  @table_name :event_log
  @max_events 500
  @counter_key :event_counter

  # Event severities
  @severities [:info, :warning, :critical]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ets.new(@table_name, [:named_table, :ordered_set, :public, read_concurrency: true])
    :persistent_term.put(@counter_key, 0)
    {:ok, %{}}
  end

  @doc """
  Log an event. Severity must be :info, :warning, or :critical.

  ## Examples

      EventLog.log(:info, "route_started", "Route started", %{route_id: "abc", route_name: "EPL"})
      EventLog.log(:critical, "sdi_failed", "SDI sink failed", %{route_id: "abc", device: 0})
  """
  def log(severity, type, message, metadata \\ %{})
      when severity in @severities and is_binary(type) and is_binary(message) do
    counter = :persistent_term.get(@counter_key) + 1
    :persistent_term.put(@counter_key, counter)

    event = %{
      id: counter,
      severity: severity,
      type: type,
      message: message,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }

    :ets.insert(@table_name, {counter, event})

    # Prune old events if over limit
    if counter > @max_events do
      prune_key = counter - @max_events
      :ets.select_delete(@table_name, [{{:"$1", :_}, [{:"=<", :"$1", prune_key}], [true]}])
    end

    # Broadcast to PubSub for real-time UI updates
    Phoenix.PubSub.broadcast(
      Blackgate.PubSub,
      "events",
      {:new_event, event}
    )

    :ok
  end

  @doc """
  Get recent events. Options:
  - :limit — max events to return (default 50)
  - :severity — filter by severity atom
  - :route_id — filter by route_id in metadata
  - :type — filter by event type string
  """
  def get_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    severity_filter = Keyword.get(opts, :severity)
    route_filter = Keyword.get(opts, :route_id)
    type_filter = Keyword.get(opts, :type)

    # Read all events in reverse order (newest first)
    :ets.tab2list(@table_name)
    |> Enum.map(fn {_key, event} -> event end)
    |> Enum.sort_by(& &1.id, :desc)
    |> Enum.filter(fn event ->
      (is_nil(severity_filter) or event.severity == severity_filter) and
        (is_nil(route_filter) or event.metadata[:route_id] == route_filter) and
        (is_nil(type_filter) or event.type == type_filter)
    end)
    |> Enum.take(limit)
  end

  @doc """
  Get count of events by severity (for badge display).
  """
  def counts do
    events = :ets.tab2list(@table_name)

    Enum.reduce(events, %{info: 0, warning: 0, critical: 0}, fn {_key, event}, acc ->
      Map.update(acc, event.severity, 1, &(&1 + 1))
    end)
  end

  @doc """
  Clear all events.
  """
  def clear do
    :ets.delete_all_objects(@table_name)
    :persistent_term.put(@counter_key, 0)
    :ok
  end
end
