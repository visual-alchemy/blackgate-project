defmodule Blackgate.SystemControl do
  @moduledoc """
  The gateway host as the Settings > System tab sees it: what the machine is, and the privileged
  actions an operator can schedule on it.

  Everything is read from the host itself (`/proc`, `df`, `systemctl`, the device tree), from the
  deployment root (`$BLACKGATE_ROOT`, updates/releases/current) and from the gateway's own state in
  Khepri and `Blackgate.RouteStatsRegistry`, so the tab reports what is actually running rather than
  what was configured.

  Actions never run directly. They go through the allowlisted root helper
  (`/usr/local/libexec/blackgate-system-action`, reached over `sudo -n`), which schedules them as
  delayed transient systemd units: restart after 3 s, reboot/shutdown after 10, deploy after 2. That
  delay is the cancel window, and it is why `scheduled_actions/0` can tell the dashboard what is
  pending. Without the helper, the sudoers drop-in and the `blackgate.service` unit — installed by
  `scripts/install-system-actions.sh` — the actions report themselves unavailable instead of failing
  in a confusing way.
  """

  alias Blackgate.Db
  alias Blackgate.EventLog
  alias Blackgate.ReleaseNotes
  alias Blackgate.RouteStatsRegistry
  alias Blackgate.SystemUpdates

  @decklink_device_pattern "/dev/blackmagic/io*"
  @documented_udp_buffer_bytes 16 * 1024 * 1024
  @engine_relative_path "priv/native/build/blackgate-engine"
  @service_unit "blackgate.service"
  @systemd_unit_paths [
    "/etc/systemd/system/blackgate.service",
    "/lib/systemd/system/blackgate.service"
  ]
  @system_action_helper "/usr/local/libexec/blackgate-system-action"
  @sudoers_path "/etc/sudoers.d/blackgate-system-action"

  # Every privileged action is scheduled as a transient systemd unit by the helper, which is what
  # makes "what is scheduled right now" — and cancelling it — answerable.
  @scheduled_units %{
    "restart_gateway" => "blackgate-dashboard-restart",
    "reboot" => "blackgate-dashboard-reboot",
    "shutdown" => "blackgate-dashboard-shutdown",
    "deploy" => "blackgate-dashboard-deploy"
  }

  @doc """
  Deployment root: the update drop box, the unpacked releases and the `current` symlink.
  `$BLACKGATE_ROOT`, `/opt/blackgate` by default (the appliance layout).
  """
  @spec root() :: String.t()
  def root, do: System.get_env("BLACKGATE_ROOT") || "/opt/blackgate"

  @doc """
  Everything the System tab shows: host identity, resources, DeckLink devices, UDP buffers, the
  engine binary in use, the service unit, the deployment root with its updates, the actions the
  dashboard may offer, and a per-route summary.
  """
  @spec status() :: map()
  def status do
    %{
      hostname: hostname(),
      os: os_pretty_name(),
      kernel: kernel_release(),
      version: app_version(),
      uptime_seconds: uptime_seconds(),
      booted_at: booted_at(),
      memory: memory(),
      disk: disk("/"),
      decklink: decklink(),
      udp_buffers: udp_buffers(),
      engine: engine(),
      service: service(),
      release: release(),
      updates: SystemUpdates.summary(),
      actions: actions(),
      routes: routes(),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Release identity as the dashboard shows it: the release notes baked into the running release, the
  version the deployment root's `current` symlink points at, and the application version.
  """
  @spec release() :: map()
  def release do
    notes = ReleaseNotes.current()

    %{
      version: (notes && notes.version) || SystemUpdates.current_version() || app_version(),
      app_version: app_version(),
      deployed: SystemUpdates.current_version(),
      released_on: notes && notes.released_on,
      changes: (notes && notes.changes) || []
    }
  end

  @doc """
  Which privileged actions this host can offer, and what is already scheduled.

  The dashboard disables what it cannot do rather than offering a button that fails: a restart needs
  the systemd unit (a hand-started node carries its environment in the shell that launched it, so
  there is no safe way to restart it), while reboot/shutdown/deploy only need the helper and the
  sudoers drop-in.
  """
  @spec actions() :: map()
  def actions do
    unit_installed = unit_installed?()
    helper_installed = File.exists?(@system_action_helper)
    sudoers_installed = File.exists?(@sudoers_path)
    privileged = helper_installed and sudoers_installed

    %{
      unit_installed: unit_installed,
      helper_installed: helper_installed,
      sudoers_installed: sudoers_installed,
      can_schedule: privileged,
      available: %{
        restart_gateway: privileged and unit_installed,
        reboot: privileged,
        shutdown: privileged,
        deploy: privileged
      },
      scheduled: scheduled_actions()
    }
  end

  @doc """
  Schedules one of the allowlisted actions through the privileged helper.

  `cancel` takes the transient unit name (`blackgate-dashboard-reboot`) as its argument; the helper
  allowlists the units it will stop.
  """
  @spec perform_action(String.t(), String.t() | nil) :: {:ok, map()} | {:error, String.t()}
  def perform_action(action, argument \\ nil) do
    with {:ok, helper_command} <- helper_command(action),
         :ok <- ensure_privileged_path() do
      args =
        if is_binary(argument) and argument != "" do
          [helper_command, argument]
        else
          [helper_command]
        end

      case run_action(args) do
        {:ok, output} ->
          audit(action, argument)

          {:ok,
           %{
             action: action,
             argument: argument,
             output: output,
             scheduled: scheduled_actions()
           }}

        {:error, message} ->
          {:error, message}
      end
    end
  end

  @doc """
  Asks the privileged updater to deploy an uploaded version. The updater verifies the signature and
  the checksum, swaps the `current` symlink and rolls back if the new release fails its health check.
  """
  @spec deploy_update(String.t()) :: {:ok, map()} | {:error, String.t()}
  def deploy_update(version) when is_binary(version), do: perform_action("deploy", version)

  @doc """
  Actions already scheduled, with the transient unit and the time systemd will run them from.
  """
  @spec scheduled_actions() :: [map()]
  def scheduled_actions do
    @scheduled_units
    |> Enum.filter(fn {_action, unit} -> unit_active?(unit) end)
    |> Enum.map(fn {action, unit} ->
      %{action: action, unit: unit, fires_at: unit_next_elapse(unit)}
    end)
  end

  defp unit_installed?, do: Enum.any?(@systemd_unit_paths, &File.exists?/1)

  defp helper_command("restart_gateway"), do: {:ok, "restart-blackgate"}
  defp helper_command("reboot"), do: {:ok, "reboot"}
  defp helper_command("shutdown"), do: {:ok, "shutdown"}
  defp helper_command("cancel"), do: {:ok, "cancel"}
  defp helper_command("deploy"), do: {:ok, "deploy"}
  defp helper_command(other), do: {:error, "unsupported action: #{other}"}

  defp ensure_privileged_path do
    cond do
      not File.exists?(@system_action_helper) ->
        {:error, "the privileged helper is not installed (#{@system_action_helper})"}

      not File.exists?(@sudoers_path) ->
        {:error, "the sudoers drop-in is not installed (#{@sudoers_path})"}

      true ->
        :ok
    end
  end

  defp run_action(args) do
    case System.cmd("sudo", ["-n", @system_action_helper | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, "helper exited #{code}: #{String.trim(output)}"}
    end
  rescue
    error -> {:error, "helper could not be run: #{inspect(error)}"}
  end

  # Actions show up in Events: an operator who reboots a gateway from the dashboard leaves a trace of
  # what was scheduled and when, next to the route events. The severity is a literal (rather
  # than a computed value) on purpose: the guidance coverage test finds event types by scanning for
  # `EventLog.log(:severity, "type"` call sites, and a variable there would hide this type from it.
  defp audit(action, argument) do
    target = if argument, do: " (#{argument})", else: ""
    metadata = %{action: action, argument: argument}
    message = "Dashboard scheduled #{action}#{target}"

    if action in ["reboot", "shutdown"] do
      EventLog.log(:warning, "system_action", message, metadata)
    else
      EventLog.log(:info, "system_action", message, metadata)
    end
  end

  defp unit_active?(unit) do
    case cmd("systemctl", ["is-active", unit <> ".timer"]) do
      {:ok, output} -> String.trim(output) == "active"
      :error -> false
    end
  end

  # `NextElapseUSecRealtime` is empty for the transient timers systemd-run creates, but `list-timers
  # --output=json` reports the real fire time (microseconds since the epoch), which is what the
  # dashboard shows while an action is counting down.
  defp unit_next_elapse(unit) do
    args = ["list-timers", unit <> ".timer", "--all", "--output=json", "--no-pager"]

    case cmd("systemctl", args) do
      {:ok, output} ->
        with {:ok, [entry | _]} <- Jason.decode(output),
             %{"next" => next} when is_integer(next) and next > 0 <- entry do
          next |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
        else
          _ -> nil
        end

      :error ->
        nil
    end
  end

  @doc """
  Plain-text dump of `status/0` plus the DeckLink firmware view, for an operator to keep or hand over.
  """
  @spec report() :: String.t()
  def report do
    status = status()

    [
      "Blackgate system report",
      "generated: #{status.generated_at}",
      "gateway version: #{status.version}",
      "",
      "host: #{status.hostname}",
      "os: #{status.os}",
      "kernel: #{status.kernel}",
      "uptime: #{format_uptime(status.uptime_seconds)} (booted #{status.booted_at || "unknown"})",
      "",
      "memory: #{memory_line(status.memory)}",
      "disk (/): #{disk_line(status.disk)}",
      "udp buffers: #{udp_buffer_line(status.udp_buffers)}",
      "decklink: #{decklink_line(status.decklink)}",
      "engine: #{engine_line(status.engine)}",
      "service: #{service_line(status.service)}",
      "",
      routes_report(status.routes),
      firmware_section()
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @doc """
  DeckLink firmware/devices as reported by Blackmagic's own tool, when it is installed and readable.
  Empty when the tool is missing or refuses to run, so the report never depends on it.
  """
  @spec firmware_section() :: [String.t()]
  def firmware_section do
    case System.find_executable("BlackmagicFirmwareUpdater") do
      nil ->
        []

      _path ->
        task = Task.async(fn -> cmd("BlackmagicFirmwareUpdater", ["status"]) end)

        case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, output}} ->
            ["", "decklink firmware:", output |> String.trim_trailing() |> indent()]

          _ ->
            []
        end
    end
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("  " <> &1))
  end

  ## Host identity

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end

  defp os_pretty_name do
    case File.read("/etc/os-release") do
      {:ok, content} -> parse_os_release(content)
      _ -> "unknown"
    end
  end

  @doc false
  def parse_os_release(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.find_value("unknown", fn line ->
      case String.split(line, "=", parts: 2) do
        ["PRETTY_NAME", value] -> value |> String.trim() |> String.trim("\"")
        _ -> nil
      end
    end)
  end

  def parse_os_release(_), do: "unknown"

  defp kernel_release do
    case cmd("uname", ["-r"]) do
      {:ok, output} -> String.trim(output)
      :error -> "unknown"
    end
  end

  defp app_version do
    case Application.spec(:blackgate, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  ## Uptime

  defp uptime_seconds do
    case File.read("/proc/uptime") do
      {:ok, content} -> parse_uptime(content)
      _ -> nil
    end
  end

  @doc false
  def parse_uptime(content) when is_binary(content) do
    case content |> String.split() |> List.first() do
      nil ->
        nil

      seconds ->
        case Float.parse(seconds) do
          {value, _} -> trunc(value)
          :error -> nil
        end
    end
  end

  def parse_uptime(_), do: nil

  defp booted_at do
    case uptime_seconds() do
      nil ->
        nil

      seconds ->
        DateTime.utc_now()
        |> DateTime.add(-seconds, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()
    end
  end

  ## Resources

  defp memory do
    case File.read("/proc/meminfo") do
      {:ok, content} -> parse_meminfo(content)
      _ -> nil
    end
  end

  @doc false
  def parse_meminfo(content) when is_binary(content) do
    values =
      content
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, rest] ->
            case rest |> String.trim() |> String.split() |> List.first() |> to_int() do
              nil -> acc
              kilobytes -> Map.put(acc, key, kilobytes)
            end

          _ ->
            acc
        end
      end)

    total_kb = values["MemTotal"]
    available_kb = values["MemAvailable"] || values["MemFree"]

    if is_integer(total_kb) and is_integer(available_kb) and total_kb > 0 do
      used_kb = total_kb - available_kb

      %{
        total_mb: kb_to_mb(total_kb),
        used_mb: kb_to_mb(used_kb),
        available_mb: kb_to_mb(available_kb),
        used_percent: Float.round(used_kb * 100 / total_kb, 1)
      }
    end
  end

  def parse_meminfo(_), do: nil

  defp disk(mount) do
    case cmd("df", ["-k", mount]) do
      {:ok, output} -> parse_df(output)
      :error -> nil
    end
  end

  @doc false
  def parse_df(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> List.first()
    |> case do
      nil ->
        nil

      line ->
        case String.split(line) do
          [_filesystem, total_kb, used_kb, available_kb | _rest] ->
            with total when is_integer(total) and total > 0 <- to_int(total_kb),
                 used when is_integer(used) <- to_int(used_kb),
                 available when is_integer(available) <- to_int(available_kb) do
              %{
                total_gb: kb_to_gb(total),
                used_gb: kb_to_gb(used),
                available_gb: kb_to_gb(available),
                used_percent: Float.round(used * 100 / total, 1)
              }
            else
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  def parse_df(_), do: nil

  ## Devices and kernel buffers

  defp decklink do
    devices = @decklink_device_pattern |> Path.wildcard() |> Enum.sort()

    %{
      device_count: length(devices),
      devices: Enum.map(devices, &Path.basename/1)
    }
  end

  defp udp_buffers do
    rmem_max = read_int("/proc/sys/net/core/rmem_max")
    wmem_max = read_int("/proc/sys/net/core/wmem_max")

    %{
      rmem_max_bytes: rmem_max,
      wmem_max_bytes: wmem_max,
      rmem_max_mb: bytes_to_mb(rmem_max),
      wmem_max_mb: bytes_to_mb(wmem_max),
      documented_min_mb: div(@documented_udp_buffer_bytes, 1024 * 1024),
      meets_documented_minimum: udp_buffers_sufficient?(rmem_max, wmem_max)
    }
  end

  @doc """
  Whether the socket buffers are at least the 16 MB this project documents for SRT at 9-50 Mbps.
  Below that the kernel drops SRT packets before the gateway ever sees them.
  """
  @spec udp_buffers_sufficient?(integer() | nil, integer() | nil) :: boolean()
  def udp_buffers_sufficient?(rmem_max, wmem_max)
      when is_integer(rmem_max) and is_integer(wmem_max) do
    rmem_max >= @documented_udp_buffer_bytes and wmem_max >= @documented_udp_buffer_bytes
  end

  def udp_buffers_sufficient?(_, _), do: false

  ## Engine binary and service unit

  defp engine do
    path = Application.app_dir(:blackgate, @engine_relative_path)

    case File.stat(path, time: :posix) do
      {:ok, stat} ->
        %{
          path: path,
          size_mb: Float.round(stat.size / 1024 / 1024, 1),
          mtime: stat.mtime |> DateTime.from_unix!() |> DateTime.to_iso8601(),
          sha256: engine_sha256(path, stat.mtime, stat.size)
        }

      _ ->
        nil
    end
  end

  defp engine_sha256(path, mtime, size) do
    key = {__MODULE__, :engine_sha256, path, mtime, size}

    case :persistent_term.get(key, nil) do
      nil ->
        digest =
          case File.read(path) do
            {:ok, binary} ->
              :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower) |> binary_part(0, 16)

            _ ->
              nil
          end

        :persistent_term.put(key, digest)
        digest

      digest ->
        digest
    end
  end

  defp service do
    active =
      case cmd("systemctl", ["is-active", @service_unit]) do
        {:ok, output} -> String.trim(output)
        :error -> "unknown"
      end

    %{
      unit: @service_unit,
      active: active,
      unit_installed: Enum.any?(@systemd_unit_paths, &File.exists?/1)
    }
  end

  ## Routes

  defp routes do
    items =
      case Db.get_all_routes() do
        {:ok, route_list} when is_list(route_list) -> Enum.map(route_list, &route_summary/1)
        _ -> []
      end

    %{
      total: length(items),
      started: Enum.count(items, &(&1.status == "started")),
      items: items
    }
  end

  @doc false
  def route_summary(route) when is_map(route) do
    stats = RouteStatsRegistry.get_stats(route["id"])
    stats_map = if stats, do: stats[:stats] || %{}, else: %{}

    %{
      id: route["id"],
      name: route["name"] || route["id"],
      status: route["status"] || "unknown",
      enabled: route["enabled"],
      schema: route["schema"],
      health: stats_map["health"],
      bandwidth_mbps: stats_map["bandwidth-mbps"],
      loss_window_10s_pct: stats_map["loss-window-10s-pct"],
      stats_updated_at: stats && stats[:updated_at]
    }
  end

  ## Report helpers

  defp routes_report(%{total: 0}), do: "routes: none configured"

  defp routes_report(%{total: total, started: started, items: items}) do
    [
      "routes (#{started}/#{total} started):",
      Enum.map(items, &route_report_line/1)
    ]
  end

  defp route_report_line(route) do
    "  - #{route.name} [#{route.status}] health=#{route.health || "unknown"}" <>
      " bandwidth=#{round_or_dash(route.bandwidth_mbps)}Mbps" <>
      " loss_10s=#{round_or_dash(route.loss_window_10s_pct)}%"
  end

  defp memory_line(nil), do: "unavailable"

  defp memory_line(memory) do
    "#{memory.used_mb} MB used / #{memory.total_mb} MB total (#{memory.used_percent}%), " <>
      "#{memory.available_mb} MB available"
  end

  defp disk_line(nil), do: "unavailable"

  defp disk_line(disk) do
    "#{disk.used_gb} GB used / #{disk.total_gb} GB total (#{disk.used_percent}%), " <>
      "#{disk.available_gb} GB available"
  end

  defp udp_buffer_line(buffers) do
    status = if buffers.meets_documented_minimum, do: "ok", else: "below the documented minimum"

    "rmem_max=#{buffers.rmem_max_mb} MB wmem_max=#{buffers.wmem_max_mb} MB " <>
      "(documented minimum #{buffers.documented_min_mb} MB: #{status})"
  end

  defp decklink_line(%{device_count: 0}), do: "no /dev/blackmagic devices"

  defp decklink_line(decklink) do
    "#{decklink.device_count} device(s): #{Enum.join(decklink.devices, ", ")}"
  end

  defp engine_line(nil), do: "engine binary not found"

  defp engine_line(engine) do
    "#{engine.path} sha256=#{engine.sha256} (#{engine.size_mb} MB, built #{engine.mtime})"
  end

  defp service_line(service) do
    installed = if service.unit_installed, do: "installed", else: "not installed"

    "#{service.unit} #{service.active} (#{installed})"
  end

  defp format_uptime(nil), do: "unknown"

  defp format_uptime(seconds) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      days > 0 -> "#{days}d #{hours}h #{minutes}m"
      hours > 0 -> "#{hours}h #{minutes}m"
      true -> "#{minutes}m"
    end
  end

  defp round_or_dash(nil), do: "-"
  defp round_or_dash(value) when is_number(value), do: Float.round(value * 1.0, 2)

  ## Small utilities

  defp read_int(path) do
    case File.read(path) do
      {:ok, content} -> to_int(content)
      _ -> nil
    end
  end

  defp to_int(nil), do: nil

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp to_int(value) when is_integer(value), do: value

  defp kb_to_mb(kilobytes) when is_integer(kilobytes), do: div(kilobytes, 1024)
  defp kb_to_gb(kilobytes) when is_integer(kilobytes), do: Float.round(kilobytes / 1024 / 1024, 1)

  defp bytes_to_mb(nil), do: nil
  defp bytes_to_mb(bytes) when is_integer(bytes), do: div(bytes, 1024 * 1024)

  defp cmd(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, _code} -> :error
    end
  rescue
    _ -> :error
  end
end
