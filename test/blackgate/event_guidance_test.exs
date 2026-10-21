defmodule Blackgate.EventGuidanceTest do
  use ExUnit.Case, async: false

  alias Blackgate.EventGuidance
  alias Blackgate.EventLog

  # Bookkeeping events: the operator has nothing to do about a route starting or stopping, so
  # their messages stay as they are.
  @bookkeeping ~w(route_started route_stopped)

  test "every event type used in the code has an action, except bookkeeping ones" do
    unknown =
      logged_types()
      |> Enum.reject(&(&1 in @bookkeeping or &1 == "health_changed"))
      |> Enum.reject(&EventGuidance.action(&1, :warning, %{}))

    assert unknown == [],
           "these event types have no action text in Blackgate.EventGuidance: #{inspect(unknown)}"
  end

  test "health_changed says what to do for every verdict" do
    verdicts = [
      "healthy",
      "warning",
      "critical",
      "network_loss_egress",
      "source_corrupted",
      "blackgate_config_issue",
      "disconnected"
    ]

    for health <- verdicts do
      assert EventGuidance.action("health_changed", :warning, %{current_health: health}),
             "no action text for health #{inspect(health)}"
    end
  end

  test "a recovery tells the operator nothing is needed" do
    assert EventGuidance.action("health_changed", :info, %{current_health: "healthy"}) =~ "none"
    assert EventGuidance.action("loss_burst", :info, %{}) =~ "none"
  end

  test "a critical verdict asks for action rather than dismissing it" do
    action = EventGuidance.action("health_changed", :critical, %{current_health: "critical"})
    refute action =~ "none"
    assert action =~ "check"
  end

  test "log/4 keeps the message short and puts the action in metadata" do
    # The Events page renders `metadata.action` as its own line, so the message carries only
    # what happened and the numbers behind it.
    EventLog.log(:warning, "watchdog_restart", "Watchdog restarted the route", %{route_name: "X"})

    event = EventLog.get_events(limit: 1) |> List.first()

    assert event.message == "Watchdog restarted the route"
    assert event.metadata[:action] =~ "CPU"
  end

  test "log/4 leaves bookkeeping events without an action" do
    EventLog.log(:info, "route_started", "Route started", %{route_name: "X"})

    event = EventLog.get_events(limit: 1) |> List.first()

    assert event.message == "Route started"
    refute Map.has_key?(event.metadata, :action)
  end

  test "log/4 rejects a severity outside info/warning/critical" do
    # A stray :error used to raise FunctionClauseError from inside the logging path, which
    # pointed at the wrong place in the code.
    assert_raise ArgumentError, ~r/invalid event severity/, fn ->
      EventLog.log(:error, "ffmpeg_missing", "ffmpeg not found on PATH")
    end
  end

  # Event types really used in the codebase, read from the call sites, so a new event cannot
  # ship without the operator being told what to do about it.
  defp logged_types do
    ~r/EventLog\.log\(\s*(?::(?:info|warning|critical),\s*)?"([a-z_]+)"/
    |> then(fn pattern ->
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&Regex.scan(pattern, File.read!(&1), capture: :all_but_first))
    end)
    |> List.flatten()
    |> Enum.uniq()
  end
end
