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
end
