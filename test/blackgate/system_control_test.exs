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
end
