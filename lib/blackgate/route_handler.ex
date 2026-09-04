defmodule Blackgate.RouteHandler do
  @moduledoc false

  require Logger
  @behaviour :gen_statem

  alias Blackgate.Db
  alias Blackgate.Helpers

  def start_link(args), do: :gen_statem.start_link(__MODULE__, args, [])

  # Reconnect configuration
  # Retry every 10 seconds
  @reconnect_interval_ms 10_000
  # Give up after 3 minutes
  @reconnect_timeout_ms 180_000

  # Watchdog configuration
  # Check every 30 seconds
  @watchdog_check_interval_ms 30_000
  # Restart if no data for 60 seconds
  @watchdog_stall_threshold_ms 60_000
  # Don't check for first 30 seconds after start
  @watchdog_grace_period_ms 30_000
  @switch_ack_timeout_ms 5_000
  @seamless_switch_ack_timeout_ms 12_000

  # SDI audio desync auto-recovery (RTMP/HTTP/HLS only)
  # Minimum total audio buffers before we treat a silence event as a hardware desync.
  # If total_buffers < this, the source itself likely has no audio — do not restart.
  @sdi_audio_min_buffers_before_restart 5_000
  # After an auto-restart for audio desync, wait this long before restarting again.
  # Prevents an infinite loop if the source permanently loses audio.
  # 5 minutes
  @sdi_audio_restart_cooldown_ms 300_000

  @impl true
  def callback_mode, do: [:handle_event_function]

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    Logger.info("RouteHandler: init route #{args.id}")

    {:ok, route} = Db.get_route(args.id, true)
    active_source = active_source_from_route(route)

    data = %{
      id: args.id,
      port: nil,
      ffmpeg_port: nil,
      route: route,
      reconnect_started_at: nil,
      reconnect_count: 0,
      last_bytes_received: 0,
      last_bytes_changed_at: nil,
      last_sdi_frames: %{},
      last_sdi_frames_changed_at: nil,
      started_at: nil,
      consecutive_startup_crashes: 0,
      # Tracks last time we auto-restarted due to SDI audio desync.
      # Used to enforce a cooldown and prevent restart loops.
      sdi_audio_last_restart_at: nil,
      active_source: active_source,
      pending_switch: nil,
      pending_switch_token: nil,
      pipeline_output_buffer: <<>>,
      failover_switched: false,
      source_health: %{primary: :unknown, secondary: :unknown},
      auto_join: Map.get(route, "auto_join", true),
      last_secondary_bytes_at: nil,
      last_secondary_bytes_received: 0,
      both_dead_reported: false
    }

    # Backfill active_source for routes created before failover feature
    if is_nil(route["active_source"]) do
      Db.update_route(args.id, %{"active_source" => "primary"})
    end

    {:ok, :start, data, {:next_event, :internal, :start}}
  end

  @impl true
  def handle_event(:internal, :start, _state, data) do
    # For RTMP/HTTP/HLS sources, spawn ffmpeg sidecar to convert to SRT
    active_route = active_route_for_pipeline(data)
    {route_for_pipeline, ffmpeg_port} = maybe_start_ffmpeg_sidecar(active_route)

    port = start_native_pipeline(route_for_pipeline)
    Logger.info("RouteHandler: Started port: #{inspect(port)}")

    case send_initial_command(port, route_for_pipeline) do
      :ok ->
        Blackgate.set_route_status(data.id, "started")
        Blackgate.set_route_error(data.id, nil)

        Blackgate.EventLog.log(:info, "route_started", "Route started", %{
          route_id: data.id,
          route_name: data.route["name"]
        })

        now = System.monotonic_time(:millisecond)

        {:next_state, :started,
         %{
           data
           | port: port,
             ffmpeg_port: ffmpeg_port,
             started_at: now,
             last_bytes_changed_at: now,
             last_sdi_frames_changed_at: now,
             last_sdi_frames: %{},
             consecutive_startup_crashes: 0,
             sdi_audio_last_restart_at: nil,
             failover_switched: false
         }, {{:timeout, :watchdog}, @watchdog_check_interval_ms, :check}}

      {:error, reason} ->
        Logger.error("RouteHandler: Failed to start: #{inspect(reason)}")
        # Kill ffmpeg if it was started
        if ffmpeg_port, do: close_port(ffmpeg_port)

        consecutive = data.consecutive_startup_crashes + 1

        if consecutive >= 3 do
          error_msg = diagnose_hardware_issue()

          Logger.error(
            "RouteHandler: Circuit breaker triggered after 3 consecutive start failures: #{error_msg}"
          )

          Blackgate.set_route_status(data.id, "error")
          Blackgate.set_route_error(data.id, error_msg)

          Blackgate.EventLog.log(
            :critical,
            "route_hardware_error",
            "Route startup failed repeatedly: #{error_msg}",
            %{
              route_id: data.id,
              route_name: data.route["name"]
            }
          )

          {:stop, :normal, %{data | consecutive_startup_crashes: consecutive}}
        else
          Blackgate.EventLog.log(
            :critical,
            "route_start_failed",
            "Route failed to start: #{inspect(reason)}",
            %{
              route_id: data.id,
              route_name: data.route["name"]
            }
          )

          {:stop, reason, %{data | consecutive_startup_crashes: consecutive}}
        end
    end
  end

  def handle_event(:info, {port, {:data, {:noeol, fragment}}}, _state, %{port: port} = data)
      when is_binary(fragment) do
    if Port.info(port) != nil do
      buffer = Map.get(data, :pipeline_output_buffer, <<>>)
      {:keep_state, Map.put(data, :pipeline_output_buffer, buffer <> fragment)}
    else
      :keep_state_and_data
    end
  end

  def handle_event(:info, {port, {:data, {:eol, fragment}}}, state, %{port: port} = data)
      when is_binary(fragment) do
    buffer = Map.get(data, :pipeline_output_buffer, <<>>)
    data = Map.put(data, :pipeline_output_buffer, <<>>)
    handle_event(:info, {port, {:data, buffer <> fragment}}, state, data)
  end

  def handle_event(:info, {port, {:data, info}}, state, %{port: port} = data) do
    # Process each line from the C pipeline stdout and check for actionable events.
    # Returns updated data if SDI audio desync recovery fires, otherwise keeps state.
    new_data =
      String.split(info, "\n")
      |> Enum.reduce(data, fn line, acc ->
        log_pipeline_line(line)

        acc =
          if String.starts_with?(line, "SOURCE_SWITCHED:") do
            [_, target] = String.split(line, "SOURCE_SWITCHED:", parts: 2)
            acknowledge_switch(acc, String.trim(target))
          else
            acc
          end

        acc =
          if String.trim(line) == "PIPELINE_READY" do
            acknowledge_pending_switch(acc)
          else
            acc
          end

        acc =
          if String.starts_with?(line, "SOURCE_SWITCH_REJECTED:") do
            [_, rejection] = String.split(line, "SOURCE_SWITCH_REJECTED:", parts: 2)
            [target | reason_parts] = String.split(String.trim(rejection), ":")

            if acc.pending_switch == target do
              reason = Enum.join(reason_parts, ":")

              Logger.warning(
                "RouteHandler: seamless source switch rejected (#{reason}); restarting on #{target}"
              )

              Blackgate.EventLog.log(
                :warning,
                "failover_seamless_fallback",
                "Seamless switch unavailable; using restart fallback",
                %{route_id: acc.id, route_name: get_in(acc, [:route, "name"]) || acc.id}
              )

              send(self(), {:restart_for_source_switch, target})
              %{acc | pending_switch_token: nil}
            else
              acc
            end
          else
            acc
          end

        # Detect SDI graceful failure from C pipeline output
        if String.contains?(line, "WARNING: SDI sink") and String.contains?(line, "failed") do
          Blackgate.EventLog.log(:warning, "sdi_failed", String.trim(line), %{
            route_id: acc.id,
            route_name: get_in(acc, [:route, "name"]) || acc.id
          })
        end

        # C dual-srtsrc bin reports per-source liveness. Drive immediate
        # in-process failover on SOURCE_INVALID for dual-ingest routes.
        acc =
          if String.starts_with?(line, "SOURCE_INVALID:") do
            [_, rest] = String.split(line, "SOURCE_INVALID:", parts: 2)
            tag_src = rest |> String.trim() |> String.split(" ") |> hd()

            tag =
              if tag_src in ["primary", "secondary"], do: String.to_atom(tag_src), else: :primary

            new_acc = put_in(acc, [:source_health, tag], :invalid)

            if dual_ingest_eligible?(new_acc.route) and is_port(new_acc.port) do
              {:keep_state, final_data} = evaluate_failover(new_acc)
              final_data
            else
              new_acc
            end
          else
            acc
          end

        acc =
          if String.starts_with?(line, "SOURCE_VALID:") do
            [_, rest] = String.split(line, "SOURCE_VALID:", parts: 2)
            tag_src = rest |> String.trim() |> String.split(" ") |> hd()

            tag =
              if tag_src in ["primary", "secondary"], do: String.to_atom(tag_src), else: :primary

            put_in(acc, [:source_health, tag], :valid)
          else
            acc
          end

        # Detect SDI audio silence — log always, then check if we should auto-restart
        acc =
          if String.contains?(line, "SDI_AUDIO_SILENT:") do
            Blackgate.EventLog.log(
              :warning,
              "sdi_audio_silent",
              "SDI audio stopped: #{String.trim(line)}",
              %{
                route_id: acc.id,
                route_name: get_in(acc, [:route, "name"]) || acc.id
              }
            )

            maybe_restart_for_audio_desync(line, state, acc)
          else
            acc
          end

        # Detect SDI audio recovery
        if String.contains?(line, "SDI_AUDIO_RECOVERED:") do
          Blackgate.EventLog.log(
            :info,
            "sdi_audio_recovered",
            "SDI audio recovered: #{String.trim(line)}",
            %{
              route_id: acc.id,
              route_name: get_in(acc, [:route, "name"]) || acc.id
            }
          )
        end

        acc
      end)

    if new_data == data do
      :keep_state_and_data
    else
      {:keep_state, new_data}
    end
  end

  # Ignore delayed output from a Port that has already been replaced.
  def handle_event(:info, {port, {:data, _info}}, _state, _data) when is_port(port) do
    :keep_state_and_data
  end

  # Watchdog: check if data is still flowing
  def handle_event({:timeout, :watchdog}, :check, :started, data) do
    now = System.monotonic_time(:millisecond)

    # Skip check during grace period
    if now - data.started_at < @watchdog_grace_period_ms do
      {:keep_state_and_data, {{:timeout, :watchdog}, @watchdog_check_interval_ms, :check}}
    else
      # Dual-ingest routes never kill/respawn on stall — they switch sources
      # in-process via evaluate_failover based on stats-driven health.
      if dual_ingest_eligible?(data.route) do
        refreshed = refresh_source_health_from_stats(data)

        {:keep_state, new_data} = evaluate_failover(refreshed)
        {:keep_state, new_data, {{:timeout, :watchdog}, @watchdog_check_interval_ms, :check}}
      else
        # Get current bytes from stats registry
        current_bytes = get_total_bytes_received(data.id)

        # Determine if the route has an active SDI destination
        has_sdi_destination? =
          case data.route["destinations"] do
            destinations when is_list(destinations) ->
              Enum.any?(destinations, &(&1["schema"] == "SDI"))

            _ ->
              false
          end

        # Query latest SDI video stats
        stats =
          case Blackgate.RouteStatsRegistry.get_stats(data.id) do
            %{stats: stats} when is_map(stats) -> stats
            _ -> nil
          end

        sdi_frames_map =
          if stats && is_list(stats["sdi_video_stats"]) do
            Enum.reduce(stats["sdi_video_stats"], %{}, fn sdi_item, acc ->
              dev = sdi_item["device_number"]
              frames = sdi_item["video_frames"] || 0

              if is_integer(dev) do
                Map.put(acc, dev, frames)
              else
                acc
              end
            end)
          else
            %{}
          end

        # 1. Evaluate Network Bytes
        {last_bytes_received, last_bytes_changed_at} =
          if current_bytes > data.last_bytes_received do
            {current_bytes, now}
          else
            {data.last_bytes_received, data.last_bytes_changed_at}
          end

        # 2. Evaluate Playout Frames (only if SDI destination is present)
        playout_stalled? =
          if has_sdi_destination? do
            if map_size(sdi_frames_map) > 0 do
              # Stalled if any configured device's frame count has not advanced
              Enum.any?(sdi_frames_map, fn {dev, current_val} ->
                last_val = Map.get(data.last_sdi_frames, dev, 0)
                current_val <= last_val
              end)
            else
              # SDI destination exists but no frames/stats received yet from C pipeline
              true
            end
          else
            false
          end

        {last_sdi_frames, last_sdi_frames_changed_at} =
          if playout_stalled? do
            {data.last_sdi_frames, data.last_sdi_frames_changed_at}
          else
            {sdi_frames_map, now}
          end

        net_stall_duration = now - last_bytes_changed_at
        sdi_stall_duration = now - last_sdi_frames_changed_at

        cond do
          net_stall_duration >= @watchdog_stall_threshold_ms ->
            Logger.warning(
              "RouteHandler: Watchdog detected network stall (#{div(net_stall_duration, 1000)}s no data), restarting route"
            )

            Blackgate.EventLog.log(
              :warning,
              "watchdog_restart",
              "No data for #{div(net_stall_duration, 1000)}s, restarting route",
              %{
                route_id: data.id,
                route_name: get_in(data, [:route, "name"]) || data.id
              }
            )

            trigger_restart(data)

          sdi_stall_duration >= @watchdog_stall_threshold_ms ->
            Logger.warning(
              "RouteHandler: Watchdog detected SDI playout freeze (#{div(sdi_stall_duration, 1000)}s no frames), restarting route"
            )

            Blackgate.EventLog.log(
              :warning,
              "watchdog_restart",
              "SDI playout frozen for #{div(sdi_stall_duration, 1000)}s, restarting route",
              %{
                route_id: data.id,
                route_name: get_in(data, [:route, "name"]) || data.id
              }
            )

            trigger_restart(data)

          true ->
            updated_data = %{
              data
              | last_bytes_received: last_bytes_received,
                last_bytes_changed_at: last_bytes_changed_at,
                last_sdi_frames: last_sdi_frames,
                last_sdi_frames_changed_at: last_sdi_frames_changed_at
            }

            {:keep_state, updated_data,
             {{:timeout, :watchdog}, @watchdog_check_interval_ms, :check}}
        end
      end
    end
  end

  # Pipeline process exited — enter reconnecting state
  def handle_event(:info, {port, {:exit_status, status}}, :started, data)
      when is_port(port) do
    cond do
      port == data.port ->
        # GStreamer pipeline exited
        Logger.warning(
          "RouteHandler: Pipeline exited with status #{status}, entering reconnect mode"
        )

        # Calculate uptime to check if this is a startup crash
        uptime = System.monotonic_time(:millisecond) - data.started_at
        consecutive = if uptime < 15_000, do: data.consecutive_startup_crashes + 1, else: 0

        if consecutive >= 3 do
          error_msg = diagnose_hardware_issue()

          Logger.error(
            "RouteHandler: Circuit breaker triggered after 3 consecutive startup crashes: #{error_msg}"
          )

          Blackgate.set_route_status(data.id, "error")
          Blackgate.set_route_error(data.id, error_msg)

          Blackgate.EventLog.log(
            :critical,
            "route_hardware_error",
            "Route crashed repeatedly on startup: #{error_msg}",
            %{
              route_id: data.id,
              route_name: get_in(data, [:route, "name"]) || data.id
            }
          )

          # Kill ffmpeg too if running
          if data.ffmpeg_port && is_port(data.ffmpeg_port), do: close_port(data.ffmpeg_port)

          {:stop, :normal,
           %{data | port: nil, ffmpeg_port: nil, consecutive_startup_crashes: consecutive}}
        else
          cleared = %{data | port: nil, consecutive_startup_crashes: consecutive}

          if is_binary(data.pending_switch) do
            enter_reconnecting(%{cleared | active_source: data.pending_switch}, 250)
          else
            trigger_restart(cleared)
          end
        end

      port == data.ffmpeg_port ->
        # ffmpeg sidecar exited — pipeline will likely follow
        Logger.warning(
          "RouteHandler: FFmpeg sidecar exited with status #{status}, entering reconnect mode"
        )

        # Kill the pipeline too since it depends on ffmpeg
        if port_open?(data.port), do: close_port(data.port)
        trigger_restart(%{data | port: nil, ffmpeg_port: nil})

      true ->
        :keep_state_and_data
    end
  end

  # Reconnect timer fired — attempt to restart the pipeline
  def handle_event({:timeout, :reconnect}, :retry, :reconnecting, data) do
    elapsed = System.monotonic_time(:millisecond) - data.reconnect_started_at

    if elapsed >= @reconnect_timeout_ms do
      cond do
        maintain_primary_fallback_eligible?(data) ->
          # One-shot fallback: primary would not reconnect within the timeout
          # window, so switch to the configured secondary source once and give
          # it a fresh reconnect window. failover_switched prevents repeat hops.
          Blackgate.EventLog.log(
            :warning,
            "failover_primary_timeout",
            "Primary source did not reconnect within #{div(@reconnect_timeout_ms, 1000)}s, " <>
              "falling back to secondary source",
            %{
              route_id: data.id,
              route_name: get_in(data, [:route, "name"]) || data.id
            }
          )

          {:next_state, :reconnecting,
           %{
             data
             | active_source: "secondary",
               pending_switch: "secondary",
               pending_switch_token: nil,
               failover_switched: true,
               reconnect_started_at: System.monotonic_time(:millisecond),
               reconnect_count: 0
           }, {{:timeout, :reconnect}, @reconnect_interval_ms, :retry}}

        true ->
          # Timeout exceeded — give up
          Logger.error("RouteHandler: Reconnect timeout (#{div(elapsed, 1000)}s), stopping route")
          Blackgate.set_route_status(data.id, "stopped")

          Blackgate.EventLog.log(
            :critical,
            "reconnect_failed",
            "Reconnect failed after #{data.reconnect_count} attempts (#{div(elapsed, 1000)}s), route stopped",
            %{
              route_id: data.id,
              route_name: get_in(data, [:route, "name"]) || data.id
            }
          )

          {:stop, :normal, data}
      end
    else
      # Attempt reconnect
      count = data.reconnect_count + 1
      Logger.info("RouteHandler: Reconnect attempt ##{count} (#{div(elapsed, 1000)}s elapsed)")

      try do
        # Re-fetch route from DB so destinations added/edited after route start
        # are included in the new pipeline. The in-memory data.route is stale.
        {:ok, fresh_route} = Db.get_route(data.id, true)
        active_route = active_route_for_pipeline(%{data | route: fresh_route})

        {route_for_pipeline, ffmpeg_port} =
          maybe_start_ffmpeg_sidecar(active_route)

        port = start_native_pipeline(route_for_pipeline)

        case send_initial_command(port, route_for_pipeline) do
          :ok ->
            Logger.info("RouteHandler: Reconnect successful on attempt ##{count}")
            Blackgate.set_route_status(data.id, "started")
            Blackgate.set_route_error(data.id, nil)

            Blackgate.EventLog.log(
              :info,
              "route_reconnected",
              "Route reconnected after #{count} attempts",
              %{
                route_id: data.id,
                route_name: get_in(data, [:route, "name"]) || data.id
              }
            )

            now = System.monotonic_time(:millisecond)

            started_data = %{
              data
              | route: fresh_route,
                port: port,
                ffmpeg_port: ffmpeg_port,
                reconnect_started_at: nil,
                reconnect_count: 0,
                started_at: now,
                last_bytes_changed_at: now,
                last_sdi_frames_changed_at: now,
                last_sdi_frames: %{},
                last_bytes_received: 0,
                consecutive_startup_crashes: 0,
                sdi_audio_last_restart_at: nil,
                failover_switched: data.failover_switched
            }

            {:next_state, :started, started_data,
             {{:timeout, :watchdog}, @watchdog_check_interval_ms, :check}}

          {:error, _reason} ->
            if ffmpeg_port, do: close_port(ffmpeg_port)
            close_port(port)

            consecutive = data.consecutive_startup_crashes + 1

            if consecutive >= 3 do
              error_msg = diagnose_hardware_issue()

              Logger.error(
                "RouteHandler: Circuit breaker triggered during reconnect after 3 consecutive failures: #{error_msg}"
              )

              Blackgate.set_route_status(data.id, "error")
              Blackgate.set_route_error(data.id, error_msg)

              Blackgate.EventLog.log(
                :critical,
                "route_hardware_error",
                "Route startup failed repeatedly: #{error_msg}",
                %{
                  route_id: data.id,
                  route_name: get_in(data, [:route, "name"]) || data.id
                }
              )

              {:stop, :normal, %{data | consecutive_startup_crashes: consecutive}}
            else
              {:keep_state,
               %{data | reconnect_count: count, consecutive_startup_crashes: consecutive},
               {{:timeout, :reconnect}, @reconnect_interval_ms, :retry}}
            end
        end
      rescue
        e ->
          Logger.error("RouteHandler: Reconnect attempt ##{count} failed: #{inspect(e)}")

          consecutive = data.consecutive_startup_crashes + 1

          if consecutive >= 3 do
            error_msg = diagnose_hardware_issue()

            Logger.error(
              "RouteHandler: Circuit breaker triggered during reconnect rescue after 3 consecutive failures: #{error_msg}"
            )

            Blackgate.set_route_status(data.id, "error")
            Blackgate.set_route_error(data.id, error_msg)

            Blackgate.EventLog.log(
              :critical,
              "route_hardware_error",
              "Route startup failed repeatedly: #{error_msg}",
              %{
                route_id: data.id,
                route_name: get_in(data, [:route, "name"]) || data.id
              }
            )

            {:stop, :normal, %{data | consecutive_startup_crashes: consecutive}}
          else
            {:keep_state,
             %{data | reconnect_count: count, consecutive_startup_crashes: consecutive},
             {{:timeout, :reconnect}, @reconnect_interval_ms, :retry}}
          end
      end
    end
  end

  # Ignore port messages during reconnecting state
  def handle_event(:info, _content, :reconnecting, _data) do
    :keep_state_and_data
  end

  # SDI audio desync auto-recovery: fired by maybe_restart_for_audio_desync/3 via send(self(), ...)
  # Using send+handle_event keeps the gen_statem state transition clean and separate from
  # the data-update return path in the pipeline stdout handler.
  def handle_event(:info, :sdi_audio_desync_restart, :started, data) do
    Logger.warning("RouteHandler: Executing SDI audio desync restart for route #{data.id}")
    trigger_restart(data)
  end

  # Already reconnecting or stopped — ignore the deferred restart message
  def handle_event(:info, :sdi_audio_desync_restart, _state, _data) do
    :keep_state_and_data
  end

  # Automatic failover for SDI or any route unsafe for raw in-process TS
  # switching. Selector never flips; new pipeline starts on requested source.
  def handle_event(
        :info,
        {:restart_for_source_switch, target},
        :started,
        %{pending_switch: target} = data
      ) do
    if port_open?(data.port), do: close_port(data.port)
    if port_open?(data.ffmpeg_port), do: close_port(data.ffmpeg_port)

    enter_reconnecting(
      %{
        data
        | active_source: target,
          pending_switch_token: nil,
          port: nil,
          ffmpeg_port: nil
      },
      250
    )
  end

  def handle_event(:info, {:restart_for_source_switch, _target}, _state, _data) do
    :keep_state_and_data
  end

  # Native accepted stdin but emitted no switch acknowledgement. Fall back to
  # restart-based selection instead of leaving route permanently pending.
  def handle_event(
        :info,
        {:switch_ack_timeout, target, token},
        :started,
        %{pending_switch: target, pending_switch_token: token} = data
      )
      when data.active_source != target do
    Logger.warning(
      "RouteHandler: native source switch acknowledgement timed out; restarting on #{target}"
    )

    if port_open?(data.port), do: close_port(data.port)
    if port_open?(data.ffmpeg_port), do: close_port(data.ffmpeg_port)

    enter_reconnecting(
      %{
        data
        | active_source: target,
          pending_switch_token: nil,
          port: nil,
          ffmpeg_port: nil
      },
      250
    )
  end

  def handle_event(:info, {:switch_ack_timeout, _target, _token}, _state, _data) do
    :keep_state_and_data
  end

  # Persistence failures after a native acknowledgement retry without changing
  # actual selection. A newer operator request supersedes stale retry messages.
  def handle_event(
        :info,
        {:persist_acknowledged_switch, target},
        _state,
        %{pending_switch: target} = data
      ) do
    {:keep_state, acknowledge_switch(data, target)}
  end

  def handle_event(:info, {:persist_acknowledged_switch, _target}, _state, _data) do
    :keep_state_and_data
  end

  # Manual source switch requested by the operator via the REST API
  # (POST /api/routes/:route_id/switch-source).
  #
  # Dual-ingest SRT routes switch in-process: the C pipeline receives a
  # "switch-source" command over stdin and selects the requested input pad
  # without tearing the pipeline down. This preserves all downstream
  # SRT connections (no reconnect storm) and is the whole point of dual-ingest.
  #
  # SDI routes use this path only when seamless_sdi_failover is explicitly
  # enabled. Native code then validates MPEG-TS compatibility and waits for a
  # target keyframe. Rejection or timeout falls back to kill/respawn.
  #
  # Non-dual-ingest routes (no failover, non-SRT secondary) or routes whose
  # pipeline port is not live also fall back to the restart path. Selection is
  # persisted only after replacement pipeline startup succeeds.
  def handle_event(:cast, {:switch_source, target}, _state, data)
      when target in ["primary", "secondary"] do
    Logger.info("RouteHandler: source switch -> #{target} for route #{data.id}")

    if in_process_switch_allowed?(data) do
      command_sent =
        Port.command(
          data.port,
          Jason.encode!(%{"command" => "switch-source", "target" => target}) <> "\n"
        )

      if command_sent do
        token = make_ref()

        Process.send_after(
          self(),
          {:switch_ack_timeout, target, token},
          switch_ack_timeout(data.route)
        )

        Blackgate.EventLog.log(
          :info,
          "failover_inprocess_switch",
          "Requested active source #{target} (in-process)",
          %{route_id: data.id, route_name: get_in(data, [:route, "name"]) || data.id}
        )

        {:keep_state,
         %{
           data
           | pending_switch: target,
             pending_switch_token: token,
             failover_switched: true,
             consecutive_startup_crashes: 0
         }}
      else
        Logger.error("RouteHandler: native port rejected source switch command")
        :keep_state_and_data
      end
    else
      Blackgate.EventLog.log(
        :info,
        "failover_manual_switch",
        "Manual source switch -> #{target} (kill/respawn)",
        %{route_id: data.id, route_name: get_in(data, [:route, "name"]) || data.id}
      )

      if port_open?(data.port), do: close_port(data.port)

      if port_open?(data.ffmpeg_port),
        do: close_port(data.ffmpeg_port)

      enter_reconnecting(
        %{
          data
          | active_source: target,
            pending_switch: target,
            pending_switch_token: nil,
            port: nil,
            ffmpeg_port: nil,
            failover_switched: false,
            consecutive_startup_crashes: 0
        },
        250
      )
    end
  end

  # Invalid switch target — log and ignore.
  def handle_event(:cast, {:switch_source, target}, _state, _data) do
    Logger.warning("RouteHandler: ignoring invalid switch_source target #{inspect(target)}")
    :keep_state_and_data
  end

  def handle_event(type, content, state, data) do
    Logger.error(
      "RouteHandler: Undefined msg type=#{inspect(type)} state=#{inspect(state)} " <>
        "route_id=#{data.id} content=#{inspect(sanitize_log_content(content))}"
    )

    :keep_state_and_data
  end

  # ===========================================================================
  # Failover Helpers (pure)
  # ===========================================================================

  @doc false
  def failover_active?(route_map) when is_map(route_map) do
    Map.get(route_map, "failover_enabled") == true and
      Map.get(route_map, "schema") == "SRT" and
      secondary_source_configured?(Map.get(route_map, "secondary_source"))
  end

  defp secondary_source_configured?(secondary) when is_map(secondary) and map_size(secondary) > 0,
    do: true

  defp secondary_source_configured?(_), do: false

  # Dual-ingest eligibility: in-process source switching is only safe when the
  # pipeline can actually receive a second SRT source. Requires failover to be
  # active (SRT primary + configured secondary) AND the secondary itself to be
  # SRT (so the C pipeline's dual-srtsrc bin can switch without restructure).
  defp route_has_sdi_destination?(route) when is_map(route) do
    destinations = Map.get(route, "destinations") || []
    Enum.any?(destinations, &(&1["schema"] == "SDI"))
  end

  defp dual_ingest_eligible?(route) do
    failover_active?(route) and
      case Map.get(route, "secondary_source") do
        %{"schema" => "SRT"} -> true
        _ -> false
      end
  end

  defp port_open?(port) when is_port(port), do: Port.info(port) != nil
  defp port_open?(_port), do: false

  defp seamless_sdi_enabled?(route) when is_map(route) do
    Map.get(route, "seamless_sdi_failover", false) == true
  end

  defp switch_ack_timeout(route) do
    if seamless_sdi_enabled?(route),
      do: @seamless_switch_ack_timeout_ms,
      else: @switch_ack_timeout_ms
  end

  defp in_process_switch_allowed?(data) do
    dual_ingest_eligible?(data.route) and
      (not route_has_sdi_destination?(data.route) or seamless_sdi_enabled?(data.route)) and
      port_open?(data.port)
  end

  defp acknowledge_pending_switch(%{pending_switch: target} = data) when is_binary(target) do
    acknowledge_switch(data, target)
  end

  defp acknowledge_pending_switch(data), do: data

  defp acknowledge_switch(%{pending_switch: target} = data, target)
       when target in ["primary", "secondary"] do
    updated_route = Map.put(data.route, "active_source", target)

    case Db.update_route(data.id, %{"active_source" => target}) do
      {:ok, _route} ->
        Blackgate.EventLog.log(
          :info,
          "failover_switch_acknowledged",
          "Native pipeline acknowledged source switch to #{target}",
          %{route_id: data.id, route_name: get_in(data, [:route, "name"]) || data.id}
        )

        %{
          data
          | active_source: target,
            route: updated_route,
            pending_switch: nil,
            pending_switch_token: nil
        }

      error ->
        Logger.error(
          "RouteHandler: failed to persist acknowledged active source: #{inspect(error)}"
        )

        Process.send_after(self(), {:persist_acknowledged_switch, target}, 1_000)

        %{data | active_source: target, route: updated_route, pending_switch_token: nil}
    end
  end

  defp acknowledge_switch(data, target) do
    Logger.warning(
      "RouteHandler: ignored unexpected source-switch acknowledgement #{inspect(target)}"
    )

    data
  end

  @doc false
  def active_source_from_route(route_map) when is_map(route_map) do
    case Map.get(route_map, "active_source") do
      source when source in ["primary", "secondary"] -> source
      _ -> "primary"
    end
  end

  @doc false
  def active_route_for_pipeline(%{route: route, active_source: active_source}) do
    overlay_secondary_source(route, active_source)
  end

  # Dual-ingest pipelines keep stable logical slots and tell native which pad
  # should start active. Swapping source configs would invert every later
  # switch-source command. Legacy single-source fallback still overlays the
  # selected secondary because it has no selector.
  defp overlay_secondary_source(route, active_source)
       when active_source in ["primary", "secondary"] do
    if dual_ingest_eligible?(route) do
      Map.put(route, "active_source", active_source)
    else
      overlay_single_source(route, active_source)
    end
  end

  defp overlay_secondary_source(route, _active_source), do: route

  defp overlay_single_source(route, "secondary") do
    case Map.get(route, "secondary_source") do
      %{"schema" => schema, "schema_options" => opts} when is_map(opts) ->
        route
        |> Map.put("schema", schema)
        |> Map.put("schema_options", opts)

      _ ->
        route
    end
  end

  defp overlay_single_source(route, _primary), do: route

  @doc false
  def choose_next_source(current_active, failover_switched, mode, _route_map) do
    case mode do
      "maintain-primary" ->
        "primary"

      "maintain-stability" ->
        toggle_source(current_active)

      "manual-switchback" ->
        if failover_switched, do: current_active, else: toggle_source(current_active)

      "manual" ->
        current_active
    end
  end

  defp toggle_source("primary"), do: "secondary"
  defp toggle_source(_other), do: "primary"

  # One-shot fallback to secondary is allowed only when failover is active, the
  # mode is maintain-primary (which otherwise insists on primary), we are
  # currently on primary, and we have not already performed the one-shot hop.
  defp maintain_primary_fallback_eligible?(data) do
    failover_active?(data.route) and
      Map.get(data.route, "failover_mode") == "maintain-primary" and
      data.active_source == "primary" and
      data.failover_switched == false
  end

  defp get_total_bytes_received(route_id) do
    case Blackgate.RouteStatsRegistry.get_stats(route_id) do
      %{stats: stats} when is_map(stats) ->
        Map.get(stats, "total-bytes-received", 0)

      _ ->
        0
    end
  end

  defp trigger_restart(data) do
    if in_process_switch_allowed?(data) do
      evaluate_failover(data)
    else
      if port_open?(data.port), do: close_port(data.port)
      if port_open?(data.ffmpeg_port), do: close_port(data.ffmpeg_port)

      cleared = %{data | port: nil, ffmpeg_port: nil}

      if failover_active?(data.route),
        do: failover_restart(cleared),
        else: enter_reconnecting(cleared)
    end
  end

  # Dual-ingest stats-driven health refresh. Pulls primary + secondary stats
  # from RouteStatsRegistry, advances the byte-change timestamps, and writes
  # source_health back into data. Pure except for the ETS reads; no side
  # effects on the port or DB.
  defp refresh_source_health_from_stats(data) do
    primary =
      case Blackgate.RouteStatsRegistry.get_stats(data.id) do
        %{stats: s} when is_map(s) -> s
        _ -> nil
      end

    secondary = Blackgate.RouteStatsRegistry.get_secondary_stats(data.id)
    now = System.monotonic_time(:millisecond)

    primary_bytes = (primary && Map.get(primary, "total-bytes-received", 0)) || 0
    secondary_bytes = (secondary && Map.get(secondary, "total-bytes-received", 0)) || 0

    last_bytes_changed_at =
      if primary_bytes > (data.last_bytes_received || 0) do
        now
      else
        data.last_bytes_changed_at
      end

    last_secondary_bytes_at =
      if secondary_bytes > (data.last_secondary_bytes_received || 0) do
        now
      else
        data.last_secondary_bytes_at
      end

    primary_health = classify_health(primary, last_bytes_changed_at, now)
    secondary_health = classify_health(secondary, last_secondary_bytes_at, now)

    %{
      data
      | source_health: %{primary: primary_health, secondary: secondary_health},
        last_bytes_changed_at: last_bytes_changed_at,
        last_bytes_received: primary_bytes,
        last_secondary_bytes_at: last_secondary_bytes_at,
        last_secondary_bytes_received: secondary_bytes
    }
  end

  defp classify_health(nil, _last_seen, _now), do: :unknown

  defp classify_health(stats, last_seen, now) when is_map(stats) do
    bytes = Map.get(stats, "total-bytes-received", 0)

    cond do
      bytes == 0 -> :invalid
      last_seen && now - last_seen > @watchdog_stall_threshold_ms -> :invalid
      true -> :valid
    end
  end

  defp classify_health(_other, _last_seen, _now), do: :unknown

  # 4-mode failover decision engine for dual-ingest SRT routes.
  #
  # Modes:
  #   maintain-primary   — prefer primary; switch away only when it dies,
  #                        switch back as soon as it recovers.
  #   maintain-stability — prefer the current source; switch only when it dies
  #                        AND the other is healthy.
  #   manual-switchback  — one-way automatic switch on failure; never switch
  #                        back without operator action.
  #   manual             — no automatic switching at all.
  #
  # When both sources are invalid the engine holds position and logs once
  # (both_dead_reported latch) to avoid log spam; the latch clears as soon as
  # any source recovers or a switch succeeds.
  defp evaluate_failover(data) do
    mode = Map.get(data.route, "failover_mode", "manual")
    h = data.source_health

    if h[:primary] == :invalid and h[:secondary] == :invalid do
      unless data.both_dead_reported do
        Blackgate.EventLog.log(
          :critical,
          "failover_both_invalid",
          "Both primary and secondary sources are invalid",
          %{route_id: data.id, route_name: get_in(data, [:route, "name"]) || data.id}
        )
      end

      {:keep_state, %{data | both_dead_reported: true}}
    else
      desired =
        case {data.active_source, mode} do
          {"primary", m}
          when m in ["maintain-primary", "maintain-stability", "manual-switchback"] ->
            if h[:primary] == :invalid, do: "secondary"

          {"secondary", "maintain-primary"} ->
            if h[:primary] == :valid, do: "primary"

          {"secondary", "maintain-stability"} ->
            if h[:secondary] == :invalid and h[:primary] == :valid, do: "primary"

          {"secondary", "manual-switchback"} ->
            nil

          _ ->
            nil
        end

      case desired do
        nil ->
          {:keep_state, %{data | both_dead_reported: false}}

        _target when is_binary(data.pending_switch) ->
          {:keep_state, data}

        target ->
          Blackgate.EventLog.log(
            :warning,
            "failover_auto",
            "Automatic source switch requested: #{target} (mode=#{mode})",
            %{route_id: data.id, route_name: get_in(data, [:route, "name"]) || data.id}
          )

          if in_process_switch_allowed?(data) do
            sent =
              Port.command(
                data.port,
                Jason.encode!(%{"command" => "switch-source", "target" => target}) <> "\n"
              )

            if sent do
              token = make_ref()

              Process.send_after(
                self(),
                {:switch_ack_timeout, target, token},
                switch_ack_timeout(data.route)
              )

              {:keep_state,
               %{
                 data
                 | pending_switch: target,
                   pending_switch_token: token,
                   failover_switched: true,
                   both_dead_reported: false
               }}
            else
              {:keep_state, data}
            end
          else
            send(self(), {:restart_for_source_switch, target})

            {:keep_state,
             %{
               data
               | pending_switch: target,
                 pending_switch_token: nil,
                 failover_switched: true,
                 both_dead_reported: false
             }}
          end
      end
    end
  end

  # Failover-aware restart. "manual" mode leaves source selection to the
  # operator, but still reconnects the currently selected source after a
  # transient pipeline/network failure. All other modes compute the next source
  # and reconnect. Persistence happens only after the replacement native
  # pipeline starts successfully.
  defp failover_restart(data) do
    mode = Map.get(data.route, "failover_mode", "manual")

    if mode == "manual" do
      Blackgate.EventLog.log(
        :warning,
        "failover_manual_reconnect",
        "Selected source disconnected in manual failover mode; reconnecting without switching source",
        %{
          route_id: data.id,
          route_name: get_in(data, [:route, "name"]) || data.id
        }
      )

      enter_reconnecting(%{data | pending_switch: nil, pending_switch_token: nil}, 250)
    else
      next =
        choose_next_source(data.active_source, data.failover_switched, mode, data.route)

      Blackgate.EventLog.log(
        :warning,
        "failover_switched",
        "Failover switched active_source #{data.active_source} -> #{next} (mode=#{mode})",
        %{
          route_id: data.id,
          route_name: get_in(data, [:route, "name"]) || data.id
        }
      )

      enter_reconnecting(
        %{data | active_source: next, pending_switch: next, pending_switch_token: nil},
        250
      )
    end
  end

  # Decides whether to auto-restart the pipeline after an SDI_AUDIO_SILENT event.
  #
  # Rules (in order):
  #   1. SRT sources → skip (SRT is self-healing, this has never happened on SRT)
  #   2. total_buffers < threshold → source has no audio, not a hardware desync → skip
  #   3. Within cooldown window → log critical, skip to avoid restart loop
  #   4. All clear → trigger restart, record timestamp
  #
  # Returns updated `data` map (with sdi_audio_last_restart_at set) if a restart was
  # triggered, or the original `data` unchanged if not.
  defp maybe_restart_for_audio_desync(line, state, data) do
    source_schema = get_in(data, [:route, "schema"]) || ""

    cond do
      # Rule 1: SRT sources are rock solid — never auto-restart for them
      source_schema == "SRT" ->
        Logger.info("RouteHandler: SDI_AUDIO_SILENT on SRT source, skipping auto-restart")
        data

      # Rule 2: Parse total_buffers — if tiny, the source itself has no audio
      true ->
        total_buffers =
          case Regex.run(~r/total_buffers=(\d+)/, line) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        cond do
          total_buffers < @sdi_audio_min_buffers_before_restart ->
            Logger.info(
              "RouteHandler: SDI_AUDIO_SILENT with total_buffers=#{total_buffers} " <>
                "(< #{@sdi_audio_min_buffers_before_restart}), source likely has no audio — skipping restart"
            )

            Blackgate.EventLog.log(
              :warning,
              "sdi_audio_source_silent",
              "SDI audio silence detected but source appears to have no audio (total_buffers=#{total_buffers})",
              %{
                route_id: data.id,
                route_name: get_in(data, [:route, "name"]) || data.id
              }
            )

            data

          # Rule 3: Within cooldown window after a previous auto-restart
          data.sdi_audio_last_restart_at != nil and
              System.monotonic_time(:millisecond) - data.sdi_audio_last_restart_at <
                @sdi_audio_restart_cooldown_ms ->
            remaining_s =
              div(
                @sdi_audio_restart_cooldown_ms -
                  (System.monotonic_time(:millisecond) - data.sdi_audio_last_restart_at),
                1000
              )

            Logger.warning(
              "RouteHandler: SDI_AUDIO_SILENT within cooldown window (#{remaining_s}s remaining), " <>
                "skipping auto-restart — manual check may be required"
            )

            Blackgate.EventLog.log(
              :critical,
              "sdi_audio_desync_repeated",
              "SDI audio desynced again within cooldown window (#{remaining_s}s remaining). " <>
                "Source audio may be intermittent — manual check required.",
              %{
                route_id: data.id,
                route_name: get_in(data, [:route, "name"]) || data.id
              }
            )

            data

          # Rule 4: Genuine hardware embedder desync — restart the pipeline
          state == :started ->
            Logger.warning(
              "RouteHandler: SDI_AUDIO_SILENT on #{source_schema} source with " <>
                "total_buffers=#{total_buffers} — triggering auto-restart for hardware desync recovery"
            )

            Blackgate.EventLog.log(
              :warning,
              "sdi_audio_desync_restart",
              "SDI audio embedder desynced (total_buffers=#{total_buffers}), auto-restarting pipeline",
              %{
                route_id: data.id,
                route_name: get_in(data, [:route, "name"]) || data.id
              }
            )

            # Record timestamp BEFORE trigger_restart (which is a gen_statem state transition)
            # We embed it in data so the reconnect path carries it forward.
            # trigger_restart will call enter_reconnecting which transitions state.
            # We return the updated data but the state transition is done as a side-effect here.
            # Since gen_statem only acts on return values from handle_event, we use
            # Process.send_after to schedule a restart command to self.
            send(self(), :sdi_audio_desync_restart)
            %{data | sdi_audio_last_restart_at: System.monotonic_time(:millisecond)}

          true ->
            # Not in :started state (already reconnecting etc.) — skip
            data
        end
    end
  end

  # retry_ms: intentional switches (manual switch, auto-failover) pass a short
  # interval — the 10s default is a crash-loop backoff, not a switch delay.
  defp enter_reconnecting(data, retry_ms \\ @reconnect_interval_ms) do
    Blackgate.set_route_status(data.id, "reconnecting")

    Blackgate.EventLog.log(
      :warning,
      "route_reconnecting",
      "Source disconnected, attempting reconnect...",
      %{
        route_id: data.id,
        route_name: get_in(data, [:route, "name"]) || data.id
      }
    )

    {:next_state, :reconnecting,
     %{
       data
       | port: nil,
         ffmpeg_port: nil,
         reconnect_started_at: System.monotonic_time(:millisecond),
         reconnect_count: 0
     }, {{:timeout, :reconnect}, retry_ms, :retry}}
  end

  @impl true
  def terminate(reason, _state, %{port: port, id: id} = data) when is_port(port) do
    Logger.info("RouteHandler: reason: #{inspect(reason)} Closing port #{inspect(port)}")
    close_port(port)
    # Also kill ffmpeg sidecar if running
    if data[:ffmpeg_port] && is_port(data.ffmpeg_port), do: close_port(data.ffmpeg_port)
    Blackgate.set_route_status(id, "stopped")
    Blackgate.RouteStatsRegistry.delete_stats(id)

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
    Blackgate.RouteStatsRegistry.delete_stats(data.id)

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

  def send_initial_command(port, route) when is_map(route) do
    with {:ok, source} <- source_from_record(route),
         {:ok, sinks} <- sinks_from_record(route) do
      payload =
        if failover_active?(route) do
          case secondary_source_from_record(route) do
            {:ok, secondary} ->
              %{
                "type" => "init",
                "route_id" => route["id"],
                "primary_source" => source,
                "secondary_source" => secondary,
                "active_source" => active_source_from_route(route),
                "auto_join" => Map.get(route, "auto_join", true),
                "seamless_sdi_failover" =>
                  seamless_sdi_enabled?(route) and route_has_sdi_destination?(route),
                "sinks" => sinks
              }

            {:error, _} ->
              %{"source" => source, "sinks" => sinks}
          end
        else
          %{"source" => source, "sinks" => sinks}
        end

      with {:ok, params} <- Jason.encode(payload),
           true <- Port.command(port, params <> "\n") do
        Logger.info("RouteHandler: sent initial command")
        :ok
      else
        error ->
          Logger.error("RouteHandler: send_initial_command failed: #{inspect(error)}")
          {:error, error}
      end
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
              "RouteHandler: sink_from_record error: #{inspect(error)}, " <>
                "destination schema: #{inspect(destination["schema"])}"
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
      |> maybe_add_param(opts, "streamid")
      |> maybe_add_param(opts, "latency")
      |> maybe_add_param(opts, "sndbuf")
      |> maybe_add_param(opts, "rcvbuf")
      |> maybe_add_param(opts, "oheadbw")
      |> maybe_add_param(opts, "maxbw")

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

  # Bind the SRT socket to a specific local source IP (NIC binding) in caller or
  # rendezvous mode. The UI exposes this as "bind-address" (an interface's IPv4);
  # the native srtsrc/srtsink element maps its "localaddress" property to the
  # local bind, distinct from the URI host. Listener mode already binds via the
  # URI host, so the bind is ignored there.
  defp maybe_add_srt_bind(props, opts) do
    mode = Map.get(opts, "mode", "")

    case Map.get(opts, "bind-address") do
      ip when ip not in [nil, ""] and mode in ["caller", "rendezvous"] ->
        Map.put(props, "localaddress", ip)

      _ ->
        props
    end
  end

  def sink_from_record(%{"schema" => "SRT", "schema_options" => opts}) do
    props =
      %{
        "type" => "srtsink",
        "uri" => build_srt_uri(opts)
      }
      |> maybe_add_srt_bind(opts)

    remaining_props =
      opts
      |> Map.drop([
        "localaddress",
        "localport",
        "mode",
        "passphrase",
        "pbkeylen",
        "poll-timeout",
        "streamid",
        "bind-address"
      ])
      |> Enum.filter(fn {key, _} ->
        key in ["latency", "sndbuf", "rcvbuf", "oheadbw", "maxbw"]
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

    # In auto-detect mode, interlaced is always false — the C pipeline determines
    # interlacing dynamically from the decoded video caps.
    # In manual mode, detect from the mode string as before.
    interlaced =
      if mode_str == "auto" do
        false
      else
        String.contains?(mode_str, "i") or mode_str in ["pal", "ntsc"]
      end

    props = %{
      "type" => "sdisink",
      "device-number" => Map.get(opts, "device_number", 0),
      "video-mode" => mode_str,
      "width" => width,
      "height" => height,
      "framerate" => framerate,
      "interlaced" => interlaced
    }

    {:ok, props}
  end

  def sink_from_record(_), do: {:error, :invalid_destination}

  # UI video_mode value -> {GStreamer mode string, width, height, framerate}
  # GStreamer mode strings (enum nicks) work regardless of plugin version.
  # video_mode=0 is "auto" — the C pipeline will detect the source and pick the mode.
  # The width/height/framerate here serve as fallback values if auto-detect can't match.
  defp sdi_video_mode_to_gst(0), do: {"auto", 1920, 1080, "25/1"}
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

      Logger.info("RouteHandler: Starting ffmpeg sidecar on loopback port #{internal_port}")

      # Spawn ffmpeg: pull source URL → remux to MPEG-TS → push SRT to internal port
      ffmpeg_cmd = build_ffmpeg_command(url, internal_port)
      Logger.debug("RouteHandler: ffmpeg command prepared with source URL redacted")

      ffmpeg_port =
        Port.open({:spawn, ffmpeg_cmd}, [
          :stderr_to_stdout,
          :use_stdio,
          :binary,
          :exit_status,
          :stream
        ])

      # Give ffmpeg time to start listening on the SRT port
      Process.sleep(3000)

      # Rewrite the route to use SRT caller on the internal port
      modified_route =
        route
        |> Map.put("schema", "SRT")
        |> Map.put("schema_options", %{
          "localaddress" => "127.0.0.1",
          "localport" => internal_port,
          "mode" => "caller",
          "latency" => 500
        })

      Blackgate.EventLog.log(:info, "ffmpeg_started", "FFmpeg sidecar started", %{
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
    reconnect_flags =
      if String.starts_with?(url, "http") do
        "-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5"
      else
        ""
      end

    "ffmpeg -hide_banner -loglevel warning " <>
      "#{reconnect_flags} " <>
      "-i \"#{url}\" " <>
      "-c copy -mpegts_copyts 0 -pcr_period 40 -f mpegts " <>
      "\"srt://127.0.0.1:#{internal_port}?mode=listener&latency=500000\""
  end

  defp find_available_port do
    # Try up to 50 random ports in the range and verify if they can be bound on localhost
    find_available_port(50)
  end

  defp find_available_port(0) do
    # Fallback to a random choice if all attempts failed
    Enum.random(@internal_port_range)
  end

  defp find_available_port(attempts) do
    port = Enum.random(@internal_port_range)

    # Check both TCP and UDP since the loopback sidecar binds on UDP for SRT
    with {:ok, tcp_socket} <-
           :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true]),
         :ok <- :gen_tcp.close(tcp_socket),
         {:ok, udp_socket} <-
           :gen_udp.open(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true]),
         :ok <- :gen_udp.close(udp_socket) do
      port
    else
      _ -> find_available_port(attempts - 1)
    end
  end

  # ===========================================================================
  # Source/Sink Configuration
  # ===========================================================================

  def source_from_record(%{"schema" => "SRT", "schema_options" => opts}) do
    props =
      %{
        "type" => "srtsrc",
        "uri" => build_srt_uri(opts)
      }
      |> maybe_add_srt_bind(opts)

    remaining_props =
      opts
      |> Map.drop([
        "localaddress",
        "localport",
        "mode",
        "passphrase",
        "pbkeylen",
        "poll-timeout",
        "bind-address"
      ])
      |> Enum.filter(fn {key, _} ->
        key in ["latency", "auto-reconnect", "keep-listening", "rcvbuf", "lossmaxttl", "oheadbw"]
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

  defp secondary_source_from_record(%{
         "secondary_source" => %{"schema" => "SRT", "schema_options" => opts}
       }),
       do: source_from_record(%{"schema" => "SRT", "schema_options" => opts})

  defp secondary_source_from_record(_), do: {:error, :no_srt_secondary}

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

  defp sanitize_pipeline_log(line) when is_binary(line) do
    redacted_uris =
      Regex.replace(
        ~r<\b(?:srt|rtmp|rtmps|https?)://[^\s"']+>i,
        line,
        "<redacted-uri>"
      )

    Regex.replace(
      ~r<(?i)(passphrase\s*[=:]\s*)[^\s,&}"']+>,
      redacted_uris,
      "\\1<redacted>"
    )
  end

  defp sanitize_pipeline_log(_line), do: "<non-binary>"

  # Native pipeline stdout is normally verbose, so routine lines stay at debug.
  # Promote actionable failures to production-visible levels; otherwise the
  # only journal evidence is an unhelpful status-0 Port exit. Sanitize before
  # logging because GStreamer diagnostics can include complete source URIs.
  defp log_pipeline_line(line) when is_binary(line) do
    sanitized = sanitize_pipeline_log(line)

    cond do
      String.starts_with?(line, "Error:") ->
        Logger.error("RouteHandler: pipeline: #{sanitized}")

      String.starts_with?(line, "Pipeline Warning") or
        String.starts_with?(line, "SOURCE_INVALID:") or
        String.starts_with?(line, "Failed to ") or
          String.starts_with?(line, "Unable to ") ->
        Logger.warning("RouteHandler: pipeline: #{sanitized}")

      true ->
        Logger.debug("RouteHandler: pipeline: #{sanitized}")
    end
  end

  defp log_pipeline_line(line),
    do: Logger.debug("RouteHandler: pipeline: #{sanitize_pipeline_log(line)}")

  defp sanitize_log_content(content) when is_binary(content), do: sanitize_pipeline_log(content)
  defp sanitize_log_content(_content), do: "<non-binary>"

  defp diagnose_hardware_issue do
    # 1. Check if GStreamer plugin is installed
    gst_status =
      case System.cmd("gst-inspect-1.0", ["decklinkvideosink"], stderr_to_stdout: true) do
        {_, 0} -> :ok
        _ -> :error
      end

    # 2. Check if DesktopVideoHelper is running
    helper_status =
      case System.cmd("pgrep", ["-f", "DesktopVideoHelper"]) do
        {_, 0} -> :ok
        _ -> :error
      end

    # 3. Check if physical hardware node exists
    dev_status =
      case System.cmd("sh", ["-c", "ls /dev/blackmagic/io*"], stderr_to_stdout: true) do
        {_, 0} -> :ok
        _ -> :error
      end

    cond do
      gst_status != :ok ->
        "GStreamer DeckLink plugin not available. Please install the gstreamer1.0-plugins-bad package."

      helper_status != :ok ->
        "Blackmagic DesktopVideoHelper service is not running. Start it with '/usr/lib/blackmagic/DesktopVideo/DesktopVideoHelper -n' or via systemctl."

      dev_status != :ok ->
        "No Blackmagic DeckLink hardware detected (missing /dev/blackmagic/io*). Check PCIe card installation."

      true ->
        "SDI Pipeline failed to initialize. The DeckLink device may be occupied by another application or in an invalid video mode."
    end
  end

  if Mix.env() == :test do
    @doc false
    def evaluate_failover_for_test(data), do: evaluate_failover(data)
  end
end
