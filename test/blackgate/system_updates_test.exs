defmodule Blackgate.SystemUpdatesTest do
  # Not async: the deployment root is process-global (an environment variable), and these tests point
  # it at a temporary directory of their own.
  use ExUnit.Case, async: false

  alias Blackgate.SystemUpdates

  setup do
    previous = System.get_env("BLACKGATE_ROOT")

    root =
      Path.join(System.tmp_dir!(), "blackgate-updates-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "incoming"))
    File.mkdir_p!(Path.join(root, "releases"))
    System.put_env("BLACKGATE_ROOT", root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous do
        System.put_env("BLACKGATE_ROOT", previous)
      else
        System.delete_env("BLACKGATE_ROOT")
      end
    end)

    {:ok, root: root}
  end

  describe "version_from_filename/1" do
    test "accepts both names the packaging script and a browser produce" do
      assert {:ok, "2026.10.21.1"} = SystemUpdates.version_from_filename("2026.10.21.1.bgupdate")

      assert {:ok, "2026.10.21.1"} =
               SystemUpdates.version_from_filename("blackgate-2026.10.21.1.bgupdate")
    end

    test "ignores any path the browser sends with it" do
      assert {:ok, "1.0.0"} =
               SystemUpdates.version_from_filename("/tmp/somewhere/blackgate-1.0.0.bgupdate")
    end

    test "refuses anything that is not a package name" do
      assert {:error, message} = SystemUpdates.version_from_filename("blackgate-1.0.0.tar.gz")
      assert message =~ "expected a <version>.bgupdate package"

      # The version becomes a file name and a path segment in the updater: no flags, no spaces.
      assert {:error, _} = SystemUpdates.version_from_filename("--flag.bgupdate")
      assert {:error, _} = SystemUpdates.version_from_filename("with space.bgupdate")
      assert {:error, _} = SystemUpdates.version_from_filename("")
    end

    test "reduces a path with directories to a plain package name" do
      # A browser may send a path; only the basename is used, so this cannot escape the incoming
      # directory (the updater then applies its own version allowlist).
      assert {:ok, version} = SystemUpdates.version_from_filename("../../etc/evil.bgupdate")
      assert version == "evil"
      refute String.contains?(version, "/")
    end
  end

  describe "uploads" do
    test "a package only becomes deployable once it is committed, and only if it is gzip" do
      assert {:ok, "2026.10.21.1", part_path} =
               SystemUpdates.prepare_upload("blackgate-2026.10.21.1.bgupdate")

      assert part_path =~ ".part"
      File.write!(part_path, <<0x1F, 0x8B>> <> :binary.copy(<<0>>, 64))

      assert {:ok, package} = SystemUpdates.commit_upload("2026.10.21.1", part_path)
      assert package.version == "2026.10.21.1"
      assert package.path == Path.join(SystemUpdates.incoming_dir(), "2026.10.21.1.bgupdate")

      assert [%{version: "2026.10.21.1", deployed?: false}] = SystemUpdates.available()
    end

    test "an HTML error page saved as a package is refused, not deployed" do
      assert {:ok, _version, part_path} = SystemUpdates.prepare_upload("2026.10.21.2.bgupdate")
      File.write!(part_path, "<html><body>404 — not found</body></html>")

      assert {:error, message} = SystemUpdates.commit_upload("2026.10.21.2", part_path)
      assert message =~ "not a gzip archive"
      assert SystemUpdates.available() == []
    end

    test "a discarded upload leaves nothing behind" do
      assert {:ok, _version, part_path} = SystemUpdates.prepare_upload("2026.10.21.3.bgupdate")
      File.write!(part_path, <<0x1F, 0x8B>>)

      assert :ok = SystemUpdates.discard_upload(part_path)
      assert SystemUpdates.available() == []
    end
  end

  describe "available/0" do
    test "lists packages newest first and marks the deployed release" do
      write_package("2026.10.20.1", 1_760_000_000)
      write_package("2026.10.21.1", 1_760_100_000)
      File.mkdir_p!(Path.join(SystemUpdates.releases_dir(), "2026.10.21.1"))
      File.ln_s("releases/2026.10.21.1", SystemUpdates.current_link())

      assert [
               %{version: "2026.10.21.1", deployed?: true, current: true},
               %{version: "2026.10.20.1", deployed?: false, current: false}
             ] = SystemUpdates.available()

      assert SystemUpdates.current_version() == "2026.10.21.1"
    end

    test "deployed releases are the rollback targets" do
      File.mkdir_p!(Path.join(SystemUpdates.releases_dir(), "2026.10.19.4"))
      File.mkdir_p!(Path.join(SystemUpdates.releases_dir(), "2026.10.21.1"))

      assert [%{version: "2026.10.21.1"}, %{version: "2026.10.19.4"}] = SystemUpdates.releases()
    end

    test "prune keeps the newest five packages" do
      for day <- 1..8 do
        write_package(
          "2026.10.#{String.pad_leading(to_string(day), 2, "0")}.1",
          1_760_000_000 + day
        )
      end

      assert length(SystemUpdates.available()) == 8
      assert :ok = SystemUpdates.prune()

      kept = SystemUpdates.available()
      assert length(kept) == 5

      assert Enum.map(kept, & &1.version) ==
               ~w(2026.10.08.1 2026.10.07.1 2026.10.06.1 2026.10.05.1 2026.10.04.1)
    end
  end

  describe "deploy_status/0 and summary/0" do
    test "report idle when the applier has not run" do
      assert is_binary(SystemUpdates.deploy_status())
    end

    test "summary carries what the Software Update card needs" do
      summary = SystemUpdates.summary()

      assert summary.root == SystemUpdates.root()
      assert is_list(summary.available)
      assert is_list(summary.releases)
      assert is_integer(summary.max_upload_mb)
      assert summary.retain == 5
    end
  end

  describe "upload limit" do
    test "accepts a release-sized package and refuses a runaway one" do
      assert SystemUpdates.within_upload_limit?(1_000_000)
      refute SystemUpdates.within_upload_limit?(10_000_000_000)
    end
  end

  defp write_package(version, mtime) do
    path = Path.join(SystemUpdates.incoming_dir(), version <> ".bgupdate")
    File.write!(path, <<0x1F, 0x8B>> <> :binary.copy(<<0>>, 128))
    File.touch!(path, mtime)
    path
  end
end
