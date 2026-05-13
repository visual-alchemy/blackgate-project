defmodule Blackgate.RouteHandler do
  @moduledoc false

  require Logger
  @behaviour :gen_statem

  alias Blackgate.Db
  alias Blackgate.Helpers

  def start_link(args), do: :gen_statem.start_link(__MODULE__, args, [])

  @impl true
  def callback_mode, do: [:handle_event_function]

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    Logger.info("RouteHandler: init: #{inspect(args)}")

    {:ok, route} = Db.get_route(args.id, true)

    data = %{
      id: args.id,
      port: nil,
      ffmpeg_port: nil,
      route: route
    }

    {:ok, :start, data, {:next_event, :internal, :start}}
  end

  @impl true
  def handle_event(:internal, :start, _state, data) do
    # For RTMP/HTTP/HLS sources, spawn ffmpeg sidecar to convert to SRT
    {route_for_pipeline, ffmpeg_port} = maybe_start_ffmpeg_sidecar(data.route)

    port = start_native_pipeline(route_for_pipeline)
    Logger.info("RouteHandler: Started port: #{inspect(port)}")

    case send_initial_command(port, route_for_pipeline) do
      :ok ->
        Blackgate.set_route_status(data.id, "started")
        Blackgate.EventLog.log(:info, "route_started", "Route started", %{
          route_id: data.id,
          route_name: data.route["name"]
        })
        {:next_state, :started, %{data | port: port, ffmpeg_port: ffmpeg_port}}

      {:error, reason} ->
        Logger.error("RouteHandler: Failed to start: #{inspect(reason)}")
        # Kill ffmpeg if it was started
        if ffmpeg_port, do: close_port(ffmpeg_port)
        Blackgate.EventLog.log(:critical, "route_start_failed", "Route failed to start: #{inspect(reason)}", %{
          route_id: data.id,
          route_name: data.route["name"]
        })
        {:stop, reason, data}
    end
  end

  def handle_event(:info, {_port, {:data, info}}, _state, data) do
    String.split(info, "\n")
    |> Enum.each(fn line ->
      Logger.warning("RouteHandler: pipeline: #{inspect(line)}")

      # Detect SDI graceful failure from C pipeline output
      if String.contains?(line, "WARNING: SDI sink") and String.contains?(line, "failed") do
        Blackgate.EventLog.log(:warning, "sdi_failed", String.trim(line), %{
          route_id: data.id,
          route_name: get_in(data, [:route, "name"]) || data.id
        })
      end
    end)

    :keep_state_and_data
  end

  def handle_event(type, content, state, data) do
    Logger.error(
      "RouteHandler: Undefined msg: #{inspect([{"type", type}, {"content", content}, {"state", state}, {"data", data}],
      pretty: true)}"
    )

    :keep_state_and_data
  end

  @impl true
  def terminate(reason, _state, %{port: port, id: id} = data) when is_port(port) do
    Logger.info("RouteHandler: reason: #{inspect(reason)} Closing port #{inspect(port)}")
    close_port(port)
    # Also kill ffmpeg sidecar if running
    if data[:ffmpeg_port] && is_port(data.ffmpeg_port), do: close_port(data.ffmpeg_port)
    Blackgate.set_route_status(id, "stopped")

    route_name = get_in(data, [:route, "name"]) || id
    case reason do
      :shutdown ->
        Blackgate.EventLog.log(:info, "route_stopped", "Route stopped", %{
          route_id: id,
          route_name: route_name
        })
      _ ->
        Blackgate.EventLog.log(:critical, "route_crashed", "Route crashed: #{inspect(reason)}", %{
          route_id: id,
          route_name: route_name
        })
    end

    :ok
  end

  def terminate(reason, _state, data) do
    Logger.info("RouteHandler: reason: #{inspect(reason)}")
    Blackgate.set_route_status(data.id, "stopped")

    route_name = get_in(data, [:route, "name"]) || data.id
    case reason do
      :shutdown ->
        Blackgate.EventLog.log(:info, "route_stopped", "Route stopped", %{
          route_id: data.id,
          route_name: route_name
        })
      _ ->
        Blackgate.EventLog.log(:critical, "route_crashed", "Route crashed: #{inspect(reason)}", %{
          route_id: data.id,
          route_name: route_name
        })
    end

    :ok
  end

  defp start_native_pipeline(route) do
    binary_path = get_binary_path()
    cmd = "#{binary_path} #{route["id"]}"

    opts = [
      :stderr_to_stdout,
      :use_stdio,
      :binary,
      :exit_status,
      :stream
    ]

    opts =
      if is_binary(route["gstDebug"]) do
        opts ++ [env: [{~c"GST_DEBUG", ~c"#{route["gstDebug"]}"}]]
      else
        opts
      end

    Logger.info("RouteHandler: start_native_pipeline: #{cmd}: #{inspect(route["gstDebug"])}")

    Port.open({:spawn, cmd}, opts)
  end

  defp get_binary_path do
    if System.get_env("RELEASE_NAME") do
      "#{:code.priv_dir(:blackgate)}/native/build/blackgate_pipeline"
    else
      "./native/build/blackgate_pipeline"
    end
  end

  defp send_initial_command(port, route) when is_map(route) do
    with {:ok, source} <- source_from_record(route),
         {:ok, sinks} <- sinks_from_record(route),
         {:ok, params} <- Jason.encode(%{"source" => source, "sinks" => sinks}),
         true <- Port.command(port, params <> "\n") do
      Logger.info("RouteHandler: sent initial command")
      :ok
    else
      error ->
        Logger.error("RouteHandler: send_initial_command failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp close_port(port) do
    try do
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) ->
          Logger.info("RouteHandler: Killing external process with PID #{pid}")
          Helpers.sys_kill(pid)

        _ ->
          Logger.warning("RouteHandler: Could not get OS PID, relying on Port.close/1")
      end

      Port.close(port)
    rescue
      error ->
        Logger.error("RouteHandler: Error closing port: #{inspect(error)}")
    end
  end

  def route_data_to_params(route_id) do
    with {:ok, route} <- Db.get_route(route_id, true),
         {:ok, source} <- source_from_record(route),
         {:ok, sinks} <- sinks_from_record(route) do
      {:ok, %{"source" => source, "sinks" => sinks}}
    end
  end

  @spec sinks_from_record(map()) :: {:ok, list()} | {:error, term()}
  def sinks_from_record(%{"destinations" => destinations})
      when is_list(destinations) and destinations != [] do
    sinks =
      destinations
      |> Enum.reduce([], fn destination, acc ->
        case sink_from_record(destination) do
          {:ok, sink} ->
            [sink | acc]

          {:error, error} ->
            Logger.error(
              "RouteHandler: sink_from_record error: #{inspect(error)}, destination: #{inspect(destination)}"
            )

            acc
        end
      end)

    {:ok, sinks}
  end

  def sinks_from_record(_) do
    Logger.warning("RouteHandler: sinks_from_record: no destinations")
    {:ok, []}
  end

  defp build_srt_uri(opts) do
    localaddress = Map.get(opts, "localaddress", "")
    localport = Map.get(opts, "localport")

    query_params =
      %{}
      |> maybe_add_param(opts, "mode")
      |> maybe_add_param(opts, "passphrase")
      |> maybe_add_param(opts, "pbkeylen")
      |> maybe_add_param(opts, "poll-timeout")

    URI.to_string(%URI{
      scheme: "srt",
      host: localaddress,
      port: localport,
      query: URI.encode_query(query_params)
    })
  end

  defp maybe_add_param(params, opts, key) do
    case Map.get(opts, key) do
      nil -> params
      "" -> params
      value -> Map.put(params, key, value)
    end
  end

  def sink_from_record(%{"schema" => "SRT", "schema_options" => opts}) do
    props = %{
      "type" => "srtsink",
      "uri" => build_srt_uri(opts)
    }

    remaining_props =
      opts
      |> Map.drop([
        "localaddress",
        "localport",
        "mode",
        "passphrase",
        "pbkeylen",
        "poll-timeout"
      ])
      |> Enum.filter(fn {key, _} ->
        key in ["latency"]
      end)
      |> Enum.into(%{})

    {:ok, Map.merge(props, remaining_props)}
  end

  def sink_from_record(%{"schema" => "UDP", "schema_options" => opts}) do
    create_sink("udpsink", opts, [
      "host",
      "port",
      "bind-address",
      "multicast-iface"
    ])
  end

  def sink_from_record(%{"schema" => "SDI", "schema_options" => opts}) do
    video_mode = Map.get(opts, "video_mode", 0)
    {mode_str, width, height, framerate} = sdi_video_mode_to_gst(video_mode)

    props = %{
      "type" => "sdisink",
      "device-number" => Map.get(opts, "device_number", 0),
      "video-mode" => mode_str,
      "width" => width,
      "height" => height,
      "framerate" => framerate
    }

    {:ok, props}
  end

  # UI video_mode value -> {GStreamer mode string, width, height, framerate}
  # GStreamer mode strings (enum nicks) work regardless of plugin version.
  defp sdi_video_mode_to_gst(9), do: {"1080p25", 1920, 1080, "25/1"}
  defp sdi_video_mode_to_gst(11), do: {"1080p30", 1920, 1080, "30/1"}
  defp sdi_video_mode_to_gst(12), do: {"1080p50", 1920, 1080, "50/1"}
  defp sdi_video_mode_to_gst(13), do: {"1080p60", 1920, 1080, "60/1"}
  defp sdi_video_mode_to_gst(7), do: {"1080i50", 1920, 1080, "25/1"}
  defp sdi_video_mode_to_gst(8), do: {"1080i60", 1920, 1080, "30/1"}
  defp sdi_video_mode_to_gst(14), do: {"720p50", 1280, 720, "50/1"}
  defp sdi_video_mode_to_gst(15), do: {"720p60", 1280, 720, "60/1"}
  defp sdi_video_mode_to_gst(17), do: {"pal", 720, 576, "25/1"}
  defp sdi_video_mode_to_gst(18), do: {"ntsc", 720, 480, "30/1"}
  defp sdi_video_mode_to_gst(22), do: {"2160p25", 3840, 2160, "25/1"}
  defp sdi_video_mode_to_gst(23), do: {"2160p30", 3840, 2160, "30/1"}
  defp sdi_video_mode_to_gst(24), do: {"2160p50", 3840, 2160, "50/1"}
  defp sdi_video_mode_to_gst(25), do: {"2160p60", 3840, 2160, "60/1"}
  defp sdi_video_mode_to_gst(_), do: {"1080p25", 1920, 1080, "25/1"}

  def sink_from_record(_), do: {:error, :invalid_destination}

  # ===========================================================================
  # FFmpeg Sidecar for RTMP/HTTP/HLS Sources
  # ===========================================================================

  @internal_port_range 39000..39999

  defp maybe_start_ffmpeg_sidecar(%{"schema" => schema, "schema_options" => opts} = route)
       when schema in ["RTMP", "HTTP", "HLS"] do
    url = Map.get(opts, "url", "")

    if url == "" do
      Logger.error("RouteHandler: RTMP source has no URL")
      {route, nil}
    else
      # Pick an available internal port for SRT loopback
      internal_port = find_available_port()
      Logger.info("RouteHandler: Starting ffmpeg sidecar: #{url} → srt://127.0.0.1:#{internal_port}")

      # Spawn ffmpeg: pull source URL → remux to MPEG-TS → push SRT to internal port
      ffmpeg_cmd = build_ffmpeg_command(url, internal_port)
      Logger.info("RouteHandler: ffmpeg command: #{ffmpeg_cmd}")

      ffmpeg_port = Port.open({:spawn, ffmpeg_cmd}, [
        :stderr_to_stdout,
        :use_stdio,
        :binary,
        :exit_status,
        :stream
      ])

      # Give ffmpeg time to start listening on the SRT port
      Process.sleep(3000)

      # Rewrite the route to use SRT caller on the internal port
      modified_route = route
        |> Map.put("schema", "SRT")
        |> Map.put("schema_options", %{
          "localaddress" => "127.0.0.1",
          "localport" => internal_port,
          "mode" => "caller",
          "latency" => 125
        })

      Blackgate.EventLog.log(:info, "ffmpeg_started", "FFmpeg sidecar started: #{url}", %{
        route_id: route["id"],
        route_name: route["name"],
        internal_port: internal_port
      })

      {modified_route, ffmpeg_port}
    end
  end

  defp maybe_start_ffmpeg_sidecar(route), do: {route, nil}

  defp build_ffmpeg_command(url, internal_port) do
    # -reconnect flags for HTTP sources (auto-retry on disconnect)
    reconnect_flags = if String.starts_with?(url, "http") do
      "-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5"
    else
      ""
    end

    "ffmpeg -hide_banner -loglevel warning " <>
      "#{reconnect_flags} " <>
      "-i \"#{url}\" " <>
      "-c copy -f mpegts " <>
      "\"srt://127.0.0.1:#{internal_port}?mode=listener&latency=125\""
  end

  defp find_available_port do
    # Simple approach: pick a random port in the range and hope it's free
    # For production, could check with :gen_tcp.listen/2
    Enum.random(@internal_port_range)
  end

  # ===========================================================================
  # Source/Sink Configuration
  # ===========================================================================

  def source_from_record(%{"schema" => "SRT", "schema_options" => opts}) do
    props = %{
      "type" => "srtsrc",
      "uri" => build_srt_uri(opts)
    }

    remaining_props =
      opts
      |> Map.drop([
        "localaddress",
        "localport",
        "mode",
        "passphrase",
        "pbkeylen",
        "poll-timeout"
      ])
      |> Enum.filter(fn {key, _} ->
        key in ["latency", "auto-reconnect", "keep-listening"]
      end)
      |> Enum.into(%{})

    {:ok, Map.merge(props, remaining_props)}
  end

  def source_from_record(%{"schema" => "UDP", "schema_options" => opts}) do
    create_source("udpsrc", opts, [
      "address",
      "port",
      "buffer-size",
      "mtu"
    ])
  end

  def source_from_record(_), do: {:error, :invalid_source}

  # Helper Functions

  defp create_source(type, opts, allowed_fields), do: build_properties(type, opts, allowed_fields)

  defp create_sink(type, opts, allowed_fields), do: build_properties(type, opts, allowed_fields)

  defp build_properties(type, opts, allowed_fields) do
    props = %{"type" => type}

    props =
      opts
      |> Enum.filter(fn {key, _} -> key in allowed_fields end)
      |> Enum.into(props)

    {:ok, props}
  end

  def dummy_params do
    %{
      "source_type" => "srtsrc",
      "source_property" => "uri",
      "source_value" => "srt://127.0.0.1:4201?mode=listener",
      "sinks" => [
        %{
          "type" => "srtsink",
          "property" => "uri",
          "value" => "srt://127.0.0.1:4205?mode=listener"
        }
      ]
    }
    |> Jason.encode!()
  end
end
