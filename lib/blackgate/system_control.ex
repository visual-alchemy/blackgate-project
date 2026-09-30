defmodule Blackgate.SystemControl do
  @moduledoc false

  @helper "/usr/local/libexec/blackgate-system-action"
  @allowed_actions ["restart-blackgate", "reboot"]
  @incoming_updates_dir "/opt/blackgate/incoming"
  @releases_dir "/opt/blackgate/releases"
  @max_retained_updates 5

  def status do
    notes = Blackgate.ReleaseNotes.current()

    %{
      hostname: command("/bin/hostname", []),
      os: os_name(),
      kernel: command("/usr/bin/uname", ["-r"]),
      uptime_seconds: uptime_seconds(),
      memory: memory(),
      disk: disk(),
      blackgate_service: command("/usr/bin/systemctl", ["is-active", "blackgate.service"]),
      version: if(notes, do: notes.version, else: release_version()),
      release_notes: notes,
      update_status: update_status()
    }
  end

  def action(action) when action in @allowed_actions do
    case System.cmd("/usr/bin/sudo", ["-n", @helper, action], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> {:error, String.trim(output)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def action(_action), do: {:error, "Unsupported system action"}

  def updates do
    case incoming_update_files() do
      {:ok, files} ->
        {:ok, files |> newest_first() |> Enum.map(&Path.basename/1)}

      {:error, :enoent} ->
        {:ok, []}

      error ->
        error
    end
  end

  def prune_incoming_updates do
    with {:ok, files} <- incoming_update_files() do
      files
      |> newest_first()
      |> Enum.drop(@max_retained_updates)
      |> Enum.reduce_while(:ok, fn path, :ok ->
        case File.rm(path) do
          :ok -> {:cont, :ok}
          {:error, :enoent} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  def prune_update_history do
    with :ok <- prune_incoming_updates(), :ok <- prune_installed_releases(), do: :ok
  end

  def deploy(version) when is_binary(version) do
    case System.cmd("/usr/bin/sudo", ["-n", @helper, "deploy", version], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def report do
    status()
    |> Enum.map(fn {key, value} -> "#{key}: #{inspect(value)}" end)
    |> Enum.sort()
    |> then(
      &Enum.join(["Blackgate system report", "generated_at: #{DateTime.utc_now()}" | &1], "\n")
    )
  end

  defp command(program, arguments) do
    case System.cmd(program, arguments, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "unavailable"
    end
  rescue
    _ -> "unavailable"
  end

  defp os_name do
    with {:ok, content} <- File.read("/etc/os-release"),
         [line | _] <- Regex.run(~r/^PRETTY_NAME=(.+)$/m, content, capture: :all_but_first) do
      String.trim(line, "\"")
    else
      _ -> "unavailable"
    end
  end

  defp uptime_seconds do
    with {:ok, content} <- File.read("/proc/uptime"),
         [seconds | _] <- String.split(content),
         {value, _} <- Float.parse(seconds) do
      trunc(value)
    else
      _ -> 0
    end
  end

  defp memory do
    values =
      case File.read("/proc/meminfo") do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Map.new(fn line ->
            case Regex.run(~r/^(\w+):\s+(\d+)/, line) do
              [_, key, value] -> {key, String.to_integer(value) * 1024}
              _ -> {line, 0}
            end
          end)

        _ ->
          %{}
      end

    total = Map.get(values, "MemTotal", 0)
    available = Map.get(values, "MemAvailable", 0)
    %{total_bytes: total, used_bytes: max(total - available, 0)}
  end

  defp disk do
    case System.cmd("/usr/bin/df", ["-B1", "--output=size,used,avail,pcent", "/"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case output
             |> String.split("\n", trim: true)
             |> List.last()
             |> String.split(~r/\s+/, trim: true) do
          [total, used, available, percent] ->
            %{
              total_bytes: String.to_integer(total),
              used_bytes: String.to_integer(used),
              available_bytes: String.to_integer(available),
              percent: percent
            }

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp release_version do
    case File.read_link("/opt/blackgate/current") do
      {:ok, target} -> Path.basename(target)
      _ -> to_string(Application.spec(:blackgate, :vsn) || "unknown")
    end
  end

  defp update_status do
    case File.read("/run/blackgate-update-status") do
      {:ok, status} -> String.trim(status)
      _ -> "idle"
    end
  end

  defp incoming_update_files do
    with {:ok, files} <- File.ls(@incoming_updates_dir) do
      {:ok,
       files
       |> Enum.filter(&String.ends_with?(&1, ".bgupdate"))
       |> Enum.map(&Path.join(@incoming_updates_dir, &1))}
    end
  end

  defp prune_installed_releases do
    with {:ok, target} <- File.read_link("/opt/blackgate/current"),
         {:ok, entries} <- File.ls(@releases_dir) do
      current = Path.basename(target)

      entries
      |> Enum.filter(&Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/, &1))
      |> Enum.map(&Path.join(@releases_dir, &1))
      |> Enum.filter(&File.dir?/1)
      |> newest_first()
      |> Enum.reject(&(Path.basename(&1) == current))
      |> Enum.drop(@max_retained_updates - 1)
      |> Enum.reduce_while(:ok, fn path, :ok ->
        case File.rm_rf(path) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason, _} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp newest_first(files) do
    Enum.sort_by(
      files,
      fn path ->
        case File.stat(path) do
          {:ok, stat} -> stat.mtime
          _ -> {{0, 1, 1}, {0, 0, 0}}
        end
      end,
      :desc
    )
  end
end
