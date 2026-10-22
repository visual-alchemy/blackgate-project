defmodule Blackgate.ReleaseNotesTest do
  use ExUnit.Case, async: true

  alias Blackgate.ReleaseNotes

  setup do
    dir = Path.join(System.tmp_dir!(), "blackgate-notes-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "reads the version, date and changes the packaging script bakes in", %{dir: dir} do
    path = Path.join(dir, "release-notes.json")

    File.write!(path, """
    {
      "version": "2026.10.21.1",
      "released_on": "2026-10-21",
      "changes": ["sink branch failures are no longer fatal", "read-only System tab"]
    }
    """)

    assert %{version: "2026.10.21.1", released_on: "2026-10-21", changes: changes} =
             ReleaseNotes.load(path)

    assert changes == ["sink branch failures are no longer fatal", "read-only System tab"]
  end

  test "tolerates a release with no changes list", %{dir: dir} do
    path = Path.join(dir, "release-notes.json")
    File.write!(path, ~s({"version": "1.0.0"}))

    assert %{version: "1.0.0", changes: []} = ReleaseNotes.load(path)
  end

  test "returns nil for a release built without notes, or with unusable ones", %{dir: dir} do
    assert ReleaseNotes.load(Path.join(dir, "missing.json")) == nil

    broken = Path.join(dir, "broken.json")
    File.write!(broken, "not json at all")
    assert ReleaseNotes.load(broken) == nil

    versionless = Path.join(dir, "versionless.json")
    File.write!(versionless, ~s({"released_on": "2026-10-21"}))
    assert ReleaseNotes.load(versionless) == nil

    empty = Path.join(dir, "empty.json")
    File.write!(empty, ~s({"version": ""}))
    assert ReleaseNotes.load(empty) == nil
  end

  test "current/0 is nil or a usable map on the running release" do
    case ReleaseNotes.current() do
      nil -> assert true
      notes -> assert is_binary(notes.version) and notes.version != ""
    end
  end
end
