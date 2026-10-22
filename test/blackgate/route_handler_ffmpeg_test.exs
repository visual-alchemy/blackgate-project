defmodule Blackgate.RouteHandlerFfmpegTest do
  use ExUnit.Case, async: true

  # The sidecar used to build a shell string with the URL interpolated inside double quotes and
  # hand it to Port.open({:spawn, ...}), i.e. to /bin/sh. A signed HTTP/HLS URL legitimately
  # contains `$`, `&`, backticks and quotes — the shell expanded, truncated or executed them
  # before ffmpeg ever saw the URL. These tests pin the argument-list contract.
  @hostile_url "https://example.invalid/live?token=$ecret&name=\"quoted\"`id`"

  test "the source URL is passed through untouched" do
    args = Blackgate.RouteHandler.ffmpeg_args(@hostile_url, 39_001)

    assert @hostile_url in args
    assert Enum.at(args, Enum.find_index(args, &(&1 == "-i")) + 1) == @hostile_url
  end

  test "the loopback SRT target is a single argument" do
    args = Blackgate.RouteHandler.ffmpeg_args("rtmp://example.invalid/live", 39_002)

    assert "srt://127.0.0.1:39002?mode=listener&latency=500000" in args
  end

  test "no argument carries a shell-escaped payload" do
    args = Blackgate.RouteHandler.ffmpeg_args(@hostile_url, 39_003)

    for arg <- args, arg != @hostile_url do
      refute String.contains?(arg, "`"), "argument looks shell-interpolated: #{arg}"
      refute String.contains?(arg, "$("), "argument looks shell-interpolated: #{arg}"
    end
  end

  test "reconnect flags are added for http sources only" do
    assert "-reconnect_streamed" in Blackgate.RouteHandler.ffmpeg_args("http://x/y", 1)
    assert "-reconnect_streamed" in Blackgate.RouteHandler.ffmpeg_args("https://x/y", 1)
    refute "-reconnect_streamed" in Blackgate.RouteHandler.ffmpeg_args("rtmp://x/y", 1)
  end

  test "the stream is remuxed, never re-encoded" do
    args = Blackgate.RouteHandler.ffmpeg_args("rtmp://x/y", 1)

    assert Enum.at(args, Enum.find_index(args, &(&1 == "-c")) + 1) == "copy"
    assert "-f" in args
    assert "mpegts" in args
  end

  describe "sidecar lifecycle" do
    # Pins the leak found on the live gateway: eleven ffmpeg processes, born three seconds apart
    # during a reconnect storm, were still running a day later with their route deleted — each
    # blocked on an SRT listener nobody read, each still holding its port. Rebuilding the pipeline
    # must reap the previous child, which means killing its OS pid, not just dropping the handle.
    test "close_recorded_handles kills the OS process, not merely the handle" do
      port = spawn_sleeper()
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      assert os_alive?(os_pid)

      cleared =
        Blackgate.RouteHandler.close_recorded_handles(%{port: port, ffmpeg_port: nil, id: "r"})

      assert cleared.port == nil
      assert cleared.ffmpeg_port == nil
      refute Port.info(port)
      refute os_alive?(os_pid)
    end

    test "clears the sidecar handle too when that is the one recorded" do
      port = spawn_sleeper()
      {:os_pid, os_pid} = Port.info(port, :os_pid)

      cleared =
        Blackgate.RouteHandler.close_recorded_handles(%{port: nil, ffmpeg_port: port, id: "r"})

      assert cleared.port == nil
      assert cleared.ffmpeg_port == nil
      refute os_alive?(os_pid)
    end

    test "tolerates a handle that already closed" do
      port = spawn_sleeper()
      Port.close(port)

      assert %{port: nil, ffmpeg_port: nil} =
               Blackgate.RouteHandler.close_recorded_handles(%{port: port, ffmpeg_port: nil})
    end

    defp spawn_sleeper do
      Port.open({:spawn_executable, "/bin/sleep"}, [:binary, :exit_status, args: ["300"]])
    end

    # A zombie still has /proc/<pid>; treat it as dead, because that is what "reaped" means here.
    defp os_alive?(pid) do
      case System.cmd("ps", ["-o", "stat=", "-p", to_string(pid)], stderr_to_stdout: true) do
        {out, 0} -> not String.starts_with?(String.trim(out), "Z")
        _ -> false
      end
    end
  end
end
