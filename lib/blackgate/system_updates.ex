defmodule Blackgate.SystemUpdates do
  @moduledoc """
  Update packages on the appliance: which ones have been uploaded, which release is deployed, what the
  privileged updater is doing, and the rollback targets already unpacked on disk.

  This module only reads and stores. Deploying goes through `Blackgate.SystemControl`, which runs the
  root updater; that updater verifies the Ed25519 signature of the manifest against
  `/etc/blackgate/update-public-key.pem`, checks the release checksum, swaps the `current` symlink
  atomically and rolls back if the new release fails its health check. Nothing here can bypass that.
  """

  alias Blackgate.SystemControl

  @package_suffix ".bgupdate"
  @max_retained 5
  @max_upload_bytes 400 * 1024 * 1024
  @status_file "/run/blackgate-update-status"
  @version_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/
  @gzip_magic <<0x1F, 0x8B>>

  @doc "Deployment root: `$BLACKGATE_ROOT`, `/opt/blackgate` by default."
  @spec root() :: String.t()
  def root, do: SystemControl.root()

  @spec incoming_dir() :: String.t()
  def incoming_dir, do: Path.join(root(), "incoming")

  @spec releases_dir() :: String.t()
  def releases_dir, do: Path.join(root(), "releases")

  @spec current_link() :: String.t()
  def current_link, do: Path.join(root(), "current")

  @spec max_upload_bytes() :: pos_integer()
  def max_upload_bytes, do: @max_upload_bytes

  @doc """
  The release the `current` symlink points at, or `nil` when nothing is deployed yet.
  """
  @spec current_version() :: String.t() | nil
  def current_version do
    case File.read_link(current_link()) do
      {:ok, target} -> Path.basename(target)
      _ -> nil
    end
  end

  @doc """
  The updater's progress line, written by the root updater to `/run/blackgate-update-status`
  (`idle`, `verifying: x`, `deploying: x`, `deployed: x`, `failed: …`).
  """
  @spec deploy_status() :: String.t()
  def deploy_status do
    case File.read(@status_file) do
      {:ok, content} -> String.trim(content)
      _ -> "idle"
    end
  end

  @doc """
  Uploaded packages, newest first. `deployed?` means the release is already unpacked under
  `releases/` (a deploy of it is a rollback to that release).
  """
  @spec available() :: [map()]
  def available do
    case File.ls(incoming_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, @package_suffix))
        |> Enum.map(&package_info/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&{&1.uploaded_at_unix, &1.filename}, :desc)
        |> Enum.map(&Map.put(&1, :current, &1.version == current_version()))

      _ ->
        []
    end
  end

  @doc """
  Releases unpacked on disk — the versions a deploy can fall back to.
  """
  @spec releases() :: [map()]
  def releases do
    case File.ls(releases_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(&1 =~ @version_pattern))
        |> Enum.map(fn version ->
          %{version: version, current: version == current_version()}
        end)
        |> Enum.sort_by(& &1.version, :desc)

      _ ->
        []
    end
  end

  @doc """
  Everything the Software Update card needs in one call.
  """
  @spec summary() :: map()
  def summary do
    %{
      root: root(),
      current_version: current_version(),
      deploy_status: deploy_status(),
      available: available(),
      releases: releases(),
      max_upload_mb: div(@max_upload_bytes, 1024 * 1024),
      retain: @max_retained
    }
  end

  @doc """
  Validates an upload's filename and returns `{:ok, version, part_path}`.

  Accepts `<version>.bgupdate` and `blackgate-<version>.bgupdate` (what the packaging script and a
  browser's file picker produce respectively). The body is written to a `.part` file so a half
  finished transfer never looks like a deployable package.
  """
  @spec prepare_upload(String.t()) :: {:ok, String.t(), Path.t()} | {:error, String.t()}
  def prepare_upload(filename) when is_binary(filename) do
    with {:ok, version} <- version_from_filename(filename),
         :ok <- prepare_incoming_dir() do
      {:ok, version, Path.join(incoming_dir(), version <> @package_suffix <> ".part")}
    end
  end

  # Errors are turned into messages here: an errno atom would reach JSON encoding and raise, and an
  # operator needs to know *which* root was used and where that root comes from — the usual cause is a
  # service that was installed without BLACKGATE_ROOT, so it fell back to /opt/blackgate.
  defp prepare_incoming_dir do
    case File.mkdir_p(incoming_dir()) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         "cannot use #{incoming_dir()}: #{:file.format_error(reason)}. The update root comes from " <>
           "BLACKGATE_ROOT (default /opt/blackgate); set it to this deployment's root in the service " <>
           "environment file (/etc/blackgate/blackgate.env) and restart the gateway."}
    end
  end

  @doc false
  @spec version_from_filename(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def version_from_filename(filename) when is_binary(filename) do
    name = Path.basename(filename)

    if String.ends_with?(name, @package_suffix) do
      version =
        name
        |> String.replace_suffix(@package_suffix, "")
        |> String.replace_prefix("blackgate-", "")

      if version =~ @version_pattern do
        {:ok, version}
      else
        {:error, "package name #{safe_name(name)} has an invalid version"}
      end
    else
      {:error, "expected a <version>.bgupdate package, got #{safe_name(name)}"}
    end
  end

  defp safe_name(name), do: String.slice(name, 0, 80)

  @doc """
  Streams a request body into the package's `.part` file, refusing anything over the upload limit.
  """
  @spec store_body(Plug.Conn.t(), Path.t()) ::
          {:ok, Plug.Conn.t(), non_neg_integer()} | {:error, String.t()}
  def store_body(conn, part_path) do
    do_store_body(conn, part_path, 0)
  end

  defp do_store_body(conn, part_path, written) do
    case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} ->
        with :ok <- write_chunk(part_path, chunk, written) do
          {:ok, conn, written + byte_size(chunk)}
        end

      # {:more, chunk, conn} carries the conn that must be used for the next read: dropping it would
      # keep re-reading the same buffer forever.
      {:more, chunk, conn} ->
        with :ok <- write_chunk(part_path, chunk, written) do
          do_store_body(conn, part_path, written + byte_size(chunk))
        end

      {:error, reason} ->
        {:error, "upload interrupted: #{inspect(reason)}"}
    end
  end

  defp write_chunk(part_path, chunk, written) do
    with :ok <- check_size(written + byte_size(chunk)) do
      case File.write(part_path, chunk, [:append]) do
        :ok -> :ok
        {:error, reason} -> {:error, "cannot write #{part_path}: #{:file.format_error(reason)}"}
      end
    end
  end

  defp check_size(size) do
    if within_upload_limit?(size) do
      :ok
    else
      {:error, "package exceeds the #{div(upload_limit_bytes(), 1024 * 1024)} MB upload limit"}
    end
  end

  @doc false
  # A whole OTP release with ERTS is tens of megabytes; 400 MB leaves room for growth while keeping a
  # runaway upload from filling the appliance's disk. Overridable for tests.
  def within_upload_limit?(size) when is_integer(size), do: size <= upload_limit_bytes()

  defp upload_limit_bytes do
    Application.get_env(:blackgate, :max_update_upload_bytes) || @max_upload_bytes
  end

  @doc """
  Finishes an upload: checks it really is a gzip archive (an HTML error page saved as a `.bgupdate`
  is the classic mistake), moves it into place and prunes the oldest packages.
  """
  @spec commit_upload(String.t(), Path.t()) :: {:ok, map()} | {:error, String.t()}
  def commit_upload(version, part_path) do
    target = Path.join(incoming_dir(), version <> @package_suffix)

    with :ok <- check_archive(part_path),
         :ok <- move_into_place(part_path, target) do
      prune()
      {:ok, %{version: version, filename: Path.basename(target), path: target}}
    end
  end

  defp move_into_place(part_path, target) do
    case File.rename(part_path, target) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot store #{target}: #{:file.format_error(reason)}"}
    end
  end

  defp check_archive(path) do
    case File.open(path, [:read, :binary], fn file -> IO.binread(file, 2) end) do
      {:ok, @gzip_magic} -> :ok
      {:ok, _other} -> {:error, "package is not a gzip archive"}
      {:error, reason} -> {:error, "package could not be read: #{inspect(reason)}"}
    end
  end

  @doc "Removes a partial upload after a failure."
  @spec discard_upload(Path.t()) :: :ok
  def discard_upload(part_path) do
    case File.rm(part_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      _other -> :ok
    end
  end

  @doc "Keeps the newest #{@max_retained} packages."
  @spec prune() :: :ok
  def prune do
    available()
    |> Enum.drop(@max_retained)
    |> Enum.each(fn package -> File.rm(Path.join(incoming_dir(), package.filename)) end)

    :ok
  end

  @doc """
  Asks the privileged updater to deploy a version. Verified, atomic and self-rolling-back — see the
  module docstring.
  """
  @spec deploy(String.t()) :: {:ok, map()} | {:error, String.t()}
  def deploy(version) when is_binary(version) do
    if version =~ @version_pattern do
      SystemControl.deploy_update(version)
    else
      {:error, "invalid version"}
    end
  end

  defp package_info(filename) do
    version = String.replace_suffix(filename, @package_suffix, "")
    path = Path.join(incoming_dir(), filename)

    case File.stat(path, time: :posix) do
      {:ok, stat} ->
        %{
          version: version,
          filename: filename,
          size_mb: Float.round(stat.size / 1024 / 1024, 1),
          uploaded_at: stat.mtime |> DateTime.from_unix!() |> DateTime.to_iso8601(),
          uploaded_at_unix: stat.mtime,
          deployed?: File.dir?(Path.join(releases_dir(), version))
        }

      _ ->
        nil
    end
  end
end
