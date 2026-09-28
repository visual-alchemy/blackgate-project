defmodule Blackgate.ReleaseNotesTest do
  use ExUnit.Case, async: true

  test "bundled notes match release version and remain independent of upload selection" do
    notes = Blackgate.ReleaseNotes.current()
    assert notes.version == String.trim(File.read!("iso-builder/release-version"))
    assert notes.changes != []
    assert {:ok, _} = Date.from_iso8601(notes.released_on)
  end

  @tag :tmp_dir
  test "absent or malformed notes have a safe fallback", %{tmp_dir: dir} do
    path = Path.join(dir, "notes.json")
    assert Blackgate.ReleaseNotes.load(path) == nil

    for content <- [
          "bad json",
          "null",
          "{}",
          Jason.encode!(%{
            version: "2026.09.17.1",
            released_on: "invalid",
            changes: ["Change"]
          }),
          Jason.encode!(%{
            version: "2026.09.17.1",
            released_on: "2026-09-17",
            changes: [123]
          })
        ] do
      File.write!(path, content)
      assert Blackgate.ReleaseNotes.load(path) == nil
    end
  end

  @tag :tmp_dir
  test "reading another installed release returns only its own notes", %{tmp_dir: dir} do
    path = Path.join(dir, "notes.json")

    File.write!(
      path,
      Jason.encode!(%{
        version: "2026.09.16.3",
        released_on: "2026-09-16",
        changes: ["Previous release change"]
      })
    )

    assert %{version: "2026.09.16.3", changes: ["Previous release change"]} =
             Blackgate.ReleaseNotes.load(path)
  end

  test "warning countdown uses evaluated gateway time without changing expiry decisions" do
    cache = %{status: :licensed, deadline: 1_800_000_000}
    assert Blackgate.License.evaluate(cache, 1_799_913_600).expires_in_seconds == 86_400
    assert Blackgate.License.evaluate(cache, 1_800_000_000).expires_in_seconds == 0
    assert Blackgate.License.evaluate(cache, 1_800_000_000).expired

    assert Blackgate.License.evaluate(%{status: :licensed}, 1_800_000_000).expires_in_seconds ==
             nil
  end
end
