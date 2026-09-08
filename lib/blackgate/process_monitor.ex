defmodule Blackgate.ProcessMonitor do
  @moduledoc false

  # `ps %CPU` is a process-lifetime average. Sample procfs twice instead so
  # the system pipeline screen shows what each live pipeline consumes now.
  @linux_cpu_sample_ms 250

  def list_pipeline_processes do
    case :os.type() do
      {:unix, :darwin} -> list_pipeline_processes_darwin()
      {:unix, :linux} -> list_pipeline_processes_linux()
      _ -> {:error, "Unsupported operating system"}
    end
  end

  def list_pipeline_processes_detailed do
    case :os.type() do
      {:unix, :darwin} -> list_pipeline_processes_detailed_darwin()
      {:unix, :linux} -> list_pipeline_processes_detailed_linux()
      _ -> {:error, "Unsupported operating system"}
    end
  end

  defp list_pipeline_processes_darwin do
    {output, 0} = System.cmd("ps", ["-eo", "pid,%cpu,%mem,vsz,rss,user,lstart,command", "-ww"])

    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.filter(&String.contains?(&1, "blackgate_pipeline"))
    |> Enum.map(&parse_process_darwin/1)
  end

  defp list_pipeline_processes_detailed_darwin do
    {output, 0} =
      System.cmd("ps", [
        "-eo",
        "pid,%cpu,%mem,vsz,rss,time,state,ppid,user,lstart,command",
        "-ww"
      ])

    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.filter(&String.contains?(&1, "blackgate_pipeline"))
    |> Enum.map(&parse_process_detailed_darwin/1)
  end

  defp parse_process_darwin(line) do
    parts = line |> String.split(" ", trim: true)

    pid = Enum.at(parts, 0) |> String.to_integer()
    cpu = Enum.at(parts, 1) <> "%"
    memory_percent = Enum.at(parts, 2) <> "%"
    vsz = Enum.at(parts, 3) |> String.to_integer()
    rss = Enum.at(parts, 4) |> String.to_integer()
    user = Enum.at(parts, 5)

    memory_bytes = rss * 1024
    swap_bytes = max(0, (vsz - rss) * 1024)

    swap_percent =
      if vsz > 0, do: "#{Float.round(swap_bytes / (1024 * 1024 * 1024) * 100, 1)}%", else: "0.0%"

    start_time_parts = Enum.slice(parts, 6..10)
    start_time = Enum.join(start_time_parts, " ")

    command_parts = Enum.slice(parts, 11..(length(parts) - 1))
    command = Enum.join(command_parts, " ")

    %{
      pid: pid,
      cpu: cpu,
      cpu_average: cpu,
      memory: format_memory(memory_bytes),
      memory_percent: memory_percent,
      memory_bytes: memory_bytes,
      swap_percent: swap_percent,
      swap_bytes: swap_bytes,
      user: user,
      start_time: start_time,
      command: command,
      route_id: pipeline_route_id(command)
    }
  end

  defp parse_process_detailed_darwin(line) do
    parts = line |> String.split(" ", trim: true)

    pid = Enum.at(parts, 0) |> String.to_integer()
    cpu = Enum.at(parts, 1) <> "%"
    memory_percent = Enum.at(parts, 2) <> "%"
    vsz = Enum.at(parts, 3) |> String.to_integer()
    rss = Enum.at(parts, 4) |> String.to_integer()

    memory_bytes = rss * 1024
    swap_bytes = max(0, (vsz - rss) * 1024)

    swap_percent =
      if vsz > 0, do: "#{Float.round(swap_bytes / (1024 * 1024 * 1024) * 100, 1)}%", else: "0.0%"

    virtual_memory = format_memory(vsz * 1024)
    resident_memory = format_memory(memory_bytes)

    cpu_time = Enum.at(parts, 5)
    state = Enum.at(parts, 6)
    ppid = Enum.at(parts, 7) |> String.to_integer()
    user = Enum.at(parts, 8)

    start_time_parts = Enum.slice(parts, 9..13)
    start_time = Enum.join(start_time_parts, " ")

    command_parts = Enum.slice(parts, 14..(length(parts) - 1))
    command = Enum.join(command_parts, " ")

    %{
      pid: pid,
      cpu: cpu,
      cpu_average: cpu,
      memory_percent: memory_percent,
      memory_bytes: memory_bytes,
      virtual_memory: virtual_memory,
      resident_memory: resident_memory,
      swap_percent: swap_percent,
      swap_bytes: swap_bytes,
      cpu_time: cpu_time,
      state: state,
      ppid: ppid,
      user: user,
      start_time: start_time,
      command: command,
      route_id: pipeline_route_id(command)
    }
  end

  defp list_pipeline_processes_linux do
    {output, 0} =
      System.cmd("ps", ["-eo", "pid,%cpu,%mem,vsz,rss,user,lstart,cmd", "--sort=-%cpu"])

    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.filter(&String.contains?(&1, "blackgate_pipeline"))
    |> Enum.map(&parse_process_linux/1)
    |> add_linux_live_usage()
  end

  defp list_pipeline_processes_detailed_linux do
    {output, 0} =
      System.cmd("ps", [
        "-eo",
        "pid,%cpu,%mem,vsz,rss,time,s,ppid,user,lstart,cmd",
        "--sort=-%cpu"
      ])

    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.filter(&String.contains?(&1, "blackgate_pipeline"))
    |> Enum.map(&parse_process_detailed_linux/1)
    |> add_linux_live_usage()
  end

  defp parse_process_linux(line) do
    parts = line |> String.split(" ", trim: true)

    pid = Enum.at(parts, 0) |> String.to_integer()
    cpu = Enum.at(parts, 1) <> "%"
    memory_percent = Enum.at(parts, 2) <> "%"
    vsz = Enum.at(parts, 3) |> String.to_integer()
    rss = Enum.at(parts, 4) |> String.to_integer()
    user = Enum.at(parts, 5)

    memory_bytes = rss * 1024
    virtual_bytes = vsz * 1024
    swap_bytes = read_proc_swap(pid)

    start_time_parts = Enum.slice(parts, 6..10)
    start_time = Enum.join(start_time_parts, " ")

    command_parts = Enum.slice(parts, 11..(length(parts) - 1))
    command = Enum.join(command_parts, " ")

    %{
      pid: pid,
      cpu: cpu,
      cpu_average: cpu,
      memory: format_memory(memory_bytes),
      memory_percent: memory_percent,
      memory_bytes: memory_bytes,
      virtual_memory: format_memory(virtual_bytes),
      swap: format_memory(swap_bytes),
      swap_percent: format_memory_percent(swap_bytes, virtual_bytes),
      swap_bytes: swap_bytes,
      user: user,
      start_time: start_time,
      command: command,
      route_id: pipeline_route_id(command)
    }
  end

  defp parse_process_detailed_linux(line) do
    parts = line |> String.split(" ", trim: true)

    pid = Enum.at(parts, 0) |> String.to_integer()
    cpu = Enum.at(parts, 1) <> "%"
    memory_percent = Enum.at(parts, 2) <> "%"
    vsz = Enum.at(parts, 3) |> String.to_integer()
    rss = Enum.at(parts, 4) |> String.to_integer()

    memory_bytes = rss * 1024
    virtual_bytes = vsz * 1024
    swap_bytes = read_proc_swap(pid)

    virtual_memory = format_memory(virtual_bytes)
    resident_memory = format_memory(memory_bytes)

    cpu_time = Enum.at(parts, 5)
    state = Enum.at(parts, 6)
    ppid = Enum.at(parts, 7) |> String.to_integer()
    user = Enum.at(parts, 8)

    start_time_parts = Enum.slice(parts, 9..13)
    start_time = Enum.join(start_time_parts, " ")

    command_parts = Enum.slice(parts, 14..(length(parts) - 1))
    command = Enum.join(command_parts, " ")

    %{
      pid: pid,
      cpu: cpu,
      cpu_average: cpu,
      memory_percent: memory_percent,
      memory_bytes: memory_bytes,
      virtual_memory: virtual_memory,
      resident_memory: resident_memory,
      swap: format_memory(swap_bytes),
      swap_percent: format_memory_percent(swap_bytes, virtual_bytes),
      swap_bytes: swap_bytes,
      cpu_time: cpu_time,
      state: state,
      ppid: ppid,
      user: user,
      start_time: start_time,
      command: command,
      route_id: pipeline_route_id(command)
    }
  end

  defp format_memory(bytes) when is_integer(bytes) do
    cond do
      bytes > 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes > 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes > 1_024 -> "#{Float.round(bytes / 1_024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_memory_percent(_bytes, 0), do: "0.0%"

  defp format_memory_percent(bytes, total_bytes) do
    "#{Float.round(bytes / total_bytes * 100, 1)}%"
  end

  defp pipeline_route_id(command) do
    case Regex.run(~r/blackgate_pipeline\s+([^\s]+)/, command) do
      [_, route_id] -> route_id
      _ -> nil
    end
  end

  # Read actual swap usage from /proc/<pid>/status (Linux only)
  defp read_proc_swap(pid) do
    case File.read("/proc/#{pid}/status") do
      {:ok, content} ->
        case Regex.run(~r/VmSwap:\s+(\d+)\s+kB/, content) do
          [_, kb_str] -> String.to_integer(kb_str) * 1024
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp add_linux_live_usage([]), do: []

  defp add_linux_live_usage(processes) do
    clock_ticks = linux_clock_ticks()
    initial = Map.new(processes, fn %{pid: pid} -> {pid, read_linux_cpu_ticks(pid)} end)
    started_at = System.monotonic_time(:microsecond)

    Process.sleep(@linux_cpu_sample_ms)

    elapsed_us = max(1, System.monotonic_time(:microsecond) - started_at)

    Enum.map(processes, fn process ->
      live_cpu_percent =
        case {Map.get(initial, process.pid), read_linux_cpu_ticks(process.pid)} do
          {first, second} when is_integer(first) and is_integer(second) and second >= first ->
            Float.round((second - first) * 100.0 * 1_000_000 / (clock_ticks * elapsed_us), 1)

          _ ->
            nil
        end

      proc_status = read_proc_status(process.pid)

      process
      |> Map.put(:cpu, format_cpu(live_cpu_percent))
      |> Map.put(:cpu_percent, live_cpu_percent)
      |> Map.put(:cpu_sample_ms, div(elapsed_us, 1_000))
      |> Map.put(:metrics_source, "procfs interval sample")
      |> Map.put(:thread_count, proc_status.threads)
      |> Map.put(:state, proc_status.state || Map.get(process, :state))
    end)
  end

  # `/proc/<pid>/stat` fields 14 and 15 are utime and stime. The process name
  # is wrapped in parentheses and can contain spaces, so split after its final
  # closing parenthesis before indexing the remaining fields.
  defp read_linux_cpu_ticks(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [_, fields] <- String.split(stat, ") ", parts: 2),
         values <- String.split(fields, " ", trim: true),
         {utime, ""} <- Integer.parse(Enum.at(values, 11, "")),
         {stime, ""} <- Integer.parse(Enum.at(values, 12, "")) do
      utime + stime
    else
      _ -> nil
    end
  end

  defp read_proc_status(pid) do
    case File.read("/proc/#{pid}/status") do
      {:ok, content} ->
        %{
          threads: read_proc_status_integer(content, "Threads"),
          state: read_proc_status_value(content, "State")
        }

      _ ->
        %{threads: nil, state: nil}
    end
  end

  defp read_proc_status_integer(content, key) do
    case Regex.run(~r/^#{key}:\s+(\d+)/m, content) do
      [_, value] -> String.to_integer(value)
      _ -> nil
    end
  end

  defp read_proc_status_value(content, key) do
    case Regex.run(~r/^#{key}:\s+(.+)$/m, content) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp linux_clock_ticks do
    case System.cmd("getconf", ["CLK_TCK"], stderr_to_stdout: true) do
      {value, 0} ->
        case Integer.parse(String.trim(value)) do
          {ticks, ""} when ticks > 0 -> ticks
          _ -> 100
        end

      _ ->
        100
    end
  end

  defp format_cpu(nil), do: "N/A"
  defp format_cpu(percent), do: :erlang.float_to_binary(percent, decimals: 1) <> "%"
end
