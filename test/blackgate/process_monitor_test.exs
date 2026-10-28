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

  describe "engine_pid?/1" do
    test "refuses the release node itself" do
      # Settings > System > Pipelines kills whatever pid the row names, and the release node owns every
      # route's stats socket: the node's command line is beam.smp, not the engine binary.
      beam_pid = System.pid() |> String.to_integer()

      refute ProcessMonitor.engine_pid?(beam_pid)
    end

    test "refuses pid 1 and pids that are not running" do
      refute ProcessMonitor.engine_pid?(1)
      refute ProcessMonitor.engine_pid?(0)
      refute ProcessMonitor.engine_pid?(-5)
      refute ProcessMonitor.engine_pid?(999_999_999)
    end

    test "accepts a process whose command line names the engine binary" do
      # No real engine is needed: the predicate reads /proc/<pid>/cmdline, so a process we control that
      # merely carries the name proves the read works.
      #
      # Two things made this flaky (about 1 run in 3, on this branch and on the unmodified one):
      #   * the port reports the pid as soon as the child is forked, BEFORE it execs, so an immediate read
      #     could still see the parent's argv;
      #   * `sh -c "sleep 5"` let sh replace its own argv by exec'ing sleep, so the name disappeared
      #     entirely.
      # The fixture therefore keeps this shell alive, and the test waits for its command line to be
      # visible; a fixture that never becomes ready fails the wait instead of the predicate.
      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          args: ["-c", "while :; do sleep 0.2; done", "blackgate-engine"]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      try do
        assert wait_for_cmdline(os_pid, "blackgate-engine", 200),
               "fixture #{os_pid} never reported a command line naming the engine binary"

        assert ProcessMonitor.engine_pid?(os_pid)
      after
        # `Port.close/1` does NOT reap this child: the shell never reads its stdin, so it survives as an orphan
        # (PPID 1) running the loop with "blackgate-engine" in its command line. One accumulated per full suite
        # run - 324 of them on this box when it was measured - and they then appear in Settings > System >
        # Pipelines as engines with no route attached (the process monitor lists by that same string). Kill the
        # OS process explicitly.
        Port.close(port)
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end
    end
  end

  defp wait_for_cmdline(pid, needle, attempts) when attempts > 0 do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, cmdline} when is_binary(cmdline) ->
        String.contains?(cmdline, needle) ||
          (
            Process.sleep(5)
            wait_for_cmdline(pid, needle, attempts - 1)
          )

      _ ->
        Process.sleep(5)
        wait_for_cmdline(pid, needle, attempts - 1)
    end
  end

  defp wait_for_cmdline(_pid, _needle, 0), do: false
end
