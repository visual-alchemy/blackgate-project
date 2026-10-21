defmodule Blackgate.ProcessMonitorTest do
  use ExUnit.Case, async: true

  alias Blackgate.ProcessMonitor

  # Real `ps -eo ...` shape as this host prints it: the start time is five words, and everything after
  # them is the command. Parsing it by field index is where the start time and the command used to be
  # sliced off by one, so the start time carried the engine path and the command carried only the route id.
  @plain_line "4837 60.3  2.6 1824524 438044 blackga+ Wed Oct 21 10:28:27 2026 /opt/blackgate/releases/2026.10.21.5/lib/blackgate-1.0.0/priv/native/build/blackgate-engine 81f51fac-cc93-11f1-80db-fcaa149e563a"

  # The detailed listing adds cpu time, state and ppid before the user, which shifts every later field.
  @detailed_line "4837 60.3  2.6 1824524 438044 00:09:59 S 4746 blackga+ Wed Oct 21 10:28:27 2026 /opt/blackgate/releases/2026.10.21.5/lib/blackgate-1.0.0/priv/native/build/blackgate-engine 81f51fac-cc93-11f1-80db-fcaa149e563a"

  @route_id "81f51fac-cc93-11f1-80db-fcaa149e563a"
  @command "/opt/blackgate/releases/2026.10.21.5/lib/blackgate-1.0.0/priv/native/build/blackgate-engine #{@route_id}"

  describe "parse_process_linux/1" do
    test "the start time is the timestamp alone, never the engine path" do
      parsed = ProcessMonitor.parse_process_linux(@plain_line)

      assert parsed.start_time == "Wed Oct 21 10:28:27 2026"
      refute parsed.start_time =~ "blackgate-engine"
    end

    test "the command keeps the whole command line and the route id is its last word" do
      parsed = ProcessMonitor.parse_process_linux(@plain_line)

      assert parsed.command == @command
      assert parsed.route_id == @route_id
      assert parsed.pid == 4837
      assert parsed.cpu == "60.3%"
      assert parsed.cpu_average == "60.3%"
    end
  end

  describe "parse_process_detailed_linux/1" do
    test "reads cpu time, state and ppid without shifting the start time" do
      parsed = ProcessMonitor.parse_process_detailed_linux(@detailed_line)

      assert parsed.start_time == "Wed Oct 21 10:28:27 2026"
      assert parsed.command == @command
      assert parsed.route_id == @route_id
      assert parsed.cpu_time == "00:09:59"
      assert parsed.state == "S"
      assert parsed.ppid == 4746
    end

    test "exposes every key the dashboard reads" do
      parsed = ProcessMonitor.parse_process_detailed_linux(@detailed_line)

      for key <- [
            :pid,
            :cpu,
            :cpu_average,
            :memory_percent,
            :memory_bytes,
            :resident_memory,
            :virtual_memory,
            :swap,
            :swap_percent,
            :swap_bytes,
            :cpu_time,
            :state,
            :ppid,
            :user,
            :start_time,
            :command,
            :route_id
          ] do
        assert Map.has_key?(parsed, key), "missing key #{key}"
      end
    end
  end

  describe "pipeline_route_id/1" do
    test "is the last word of the command" do
      assert ProcessMonitor.pipeline_route_id(@command) == @route_id
    end

    test "is nil when the engine was started without a route id" do
      assert ProcessMonitor.pipeline_route_id(
               "/opt/blackgate/current/lib/x/priv/native/build/blackgate-engine"
             ) == nil

      assert ProcessMonitor.pipeline_route_id("") == nil
    end
  end
end
