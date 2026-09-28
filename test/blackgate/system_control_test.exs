defmodule Blackgate.SystemControlTest do
  use ExUnit.Case, async: true

  alias Blackgate.SystemControl

  test "status returns appliance-safe system facts" do
    status = SystemControl.status()

    assert is_binary(status.hostname)
    assert is_binary(status.os)
    assert is_binary(status.kernel)
    assert is_integer(status.uptime_seconds)
    assert is_map(status.memory)
    assert is_map(status.disk)
    assert is_integer(status.decklink_nodes)
  end

  test "rejects actions outside fixed allowlist" do
    assert {:error, "Unsupported system action"} = SystemControl.action("shutdown")
  end

  test "report contains no route configuration" do
    assert SystemControl.report() =~ "Blackgate system report"
    assert SystemControl.report() =~ "hostname:"
  end

  @tag :tmp_dir
  test "update-history cleanup only prunes incoming packages", %{tmp_dir: dir} do
    incoming = Path.join(dir, "incoming")
    File.mkdir_p!(incoming)

    for n <- 1..6 do
      path = Path.join(incoming, "2026.09.28.#{n}.bgupdate")
      File.write!(path, "package #{n}")
      File.touch!(path, {{2026, 9, 28}, {0, 0, n}})
    end

    File.write!(Path.join(incoming, "keep.txt"), "not an update")

    assert :ok = SystemControl.prune_update_history(incoming)
    assert {:ok, remaining} = File.ls(incoming)
    refute "2026.09.28.1.bgupdate" in remaining
    assert "keep.txt" in remaining
    assert Enum.count(remaining, &String.ends_with?(&1, ".bgupdate")) == 5
  end

  @tag :tmp_dir
  test "update-history cleanup accepts missing incoming directory", %{tmp_dir: dir} do
    assert :ok = SystemControl.prune_update_history(Path.join(dir, "missing"))
  end
end
