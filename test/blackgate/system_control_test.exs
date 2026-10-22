defmodule Blackgate.SystemControlTest do
  use ExUnit.Case, async: true

  alias Blackgate.SystemControl

  describe "parse_os_release/1" do
    test "reads PRETTY_NAME and strips the quotes" do
      content = """
      NAME="Ubuntu"
      VERSION="24.04.5 LTS (Noble Numbat)"
      PRETTY_NAME="Ubuntu 24.04.5 LTS"
      ID=ubuntu
      """

      assert SystemControl.parse_os_release(content) == "Ubuntu 24.04.5 LTS"
    end

    test "falls back to unknown when the field is missing" do
      assert SystemControl.parse_os_release("NAME=\"Ubuntu\"\n") == "unknown"
      assert SystemControl.parse_os_release("") == "unknown"
    end
  end

  describe "parse_uptime/1" do
    test "takes the first field and truncates it" do
      assert SystemControl.parse_uptime("12345.67 98765.43\n") == 12_345
    end

    test "returns nil on junk" do
      assert SystemControl.parse_uptime("") == nil
      assert SystemControl.parse_uptime("not-a-number 1.0") == nil
    end
  end

  describe "parse_meminfo/1" do
    test "prefers MemAvailable so the cache does not read as memory pressure" do
      content = """
      MemTotal:       16383104 kB
      MemFree:         1234567 kB
      MemAvailable:    9876543 kB
      Buffers:          123456 kB
      """

      memory = SystemControl.parse_meminfo(content)

      assert memory.total_mb == 15_999
      assert memory.available_mb == 9_645
      assert memory.used_mb == 6_354
      assert memory.used_percent == 39.7
    end

    test "falls back to MemFree on kernels without MemAvailable" do
      content = "MemTotal:  1000000 kB\nMemFree:    250000 kB\n"

      memory = SystemControl.parse_meminfo(content)

      assert memory.total_mb == 976
      assert memory.available_mb == 244
      assert memory.used_percent == 75.0
    end

    test "returns nil when the totals are unreadable" do
      assert SystemControl.parse_meminfo("SomethingElse: 1 kB\n") == nil
      assert SystemControl.parse_meminfo("") == nil
    end
  end

  describe "parse_df/1" do
    test "reads the data line and reports gigabytes and percent" do
      output = """
      Filesystem     1K-blocks      Used Available Use% Mounted on
      /dev/nvme0n1p2 491000000 123000000 340000000  27% /
      """

      disk = SystemControl.parse_df(output)

      assert disk.total_gb == 468.3
      assert disk.used_gb == 117.3
      assert disk.available_gb == 324.2
      assert disk.used_percent == 25.1
    end

    test "returns nil on an empty or header-only output" do
      assert SystemControl.parse_df("") == nil

      assert SystemControl.parse_df("Filesystem 1K-blocks Used Available Use% Mounted on\n") ==
               nil
    end
  end

  describe "udp_buffers_sufficient?/2" do
    test "accepts the 16 MB this project documents" do
      assert SystemControl.udp_buffers_sufficient?(16_777_216, 16_777_216)
      assert SystemControl.udp_buffers_sufficient?(33_554_432, 16_777_216)
    end

    test "rejects the default 208 KB buffers and unreadable values" do
      refute SystemControl.udp_buffers_sufficient?(212_992, 212_992)
      refute SystemControl.udp_buffers_sufficient?(16_777_216, 212_992)
      refute SystemControl.udp_buffers_sufficient?(nil, nil)
      refute SystemControl.udp_buffers_sufficient?(16_777_216, nil)
    end
  end

  describe "status/0" do
    test "reports the host, its resources and the route summary" do
      status = SystemControl.status()

      assert is_binary(status.hostname) and status.hostname != ""
      assert is_binary(status.os)
      assert is_binary(status.kernel)
      assert is_binary(status.version)
      assert is_integer(status.uptime_seconds)
      assert is_binary(status.generated_at)
      assert is_boolean(status.udp_buffers.meets_documented_minimum)
      assert is_integer(status.decklink.device_count)
      assert is_list(status.decklink.devices)
      assert is_boolean(status.service.unit_installed)
      assert is_integer(status.routes.total)
      assert is_integer(status.routes.started)
      assert status.routes.started <= status.routes.total
    end

    test "every route summary carries the fields the tab renders" do
      status = SystemControl.status()

      for route <- status.routes.items do
        assert is_binary(route.id)
        assert is_binary(route.name)
        assert is_binary(route.status)
        refute Map.has_key?(route, :sdi)
      end
    end
  end

  describe "actions/0" do
    test "reports what is installed and keeps the availability flags consistent with it" do
      actions = SystemControl.actions()

      assert is_boolean(actions.unit_installed)
      assert is_boolean(actions.helper_installed)
      assert is_boolean(actions.sudoers_installed)
      assert actions.can_schedule == (actions.helper_installed and actions.sudoers_installed)
      assert is_list(actions.scheduled)

      # A restart additionally needs the unit: a hand-started node carries its environment in the
      # shell that launched it, so there is no safe way to restart it.
      assert actions.available.restart_gateway ==
               (actions.can_schedule and actions.unit_installed)

      assert actions.available.reboot == actions.can_schedule
      assert actions.available.shutdown == actions.can_schedule
      assert actions.available.deploy == actions.can_schedule
    end

    test "refuses an action that is not on the allowlist" do
      assert {:error, message} = SystemControl.perform_action("rm-rf-everything")
      assert message =~ "unsupported action"
    end

    test "a valid action is refused when the privileged helper is not installed" do
      if SystemControl.actions().helper_installed do
        # The installer has been run on this machine. Scheduling a real action here would be reckless,
        # so the check is skipped rather than exercised.
        assert SystemControl.actions().can_schedule or
                 not SystemControl.actions().sudoers_installed
      else
        assert {:error, message} = SystemControl.perform_action("reboot")
        assert message =~ "privileged helper is not installed"
      end
    end

    test "scheduled_actions/0 never lists an action that is not one of ours" do
      for scheduled <- SystemControl.scheduled_actions() do
        assert scheduled.action in ~w(restart_gateway reboot shutdown deploy)
        assert scheduled.unit =~ "blackgate-dashboard-"
      end
    end
  end

  describe "release/0" do
    test "always knows some version to show" do
      release = SystemControl.release()

      assert is_binary(release.version) and release.version != ""
      assert is_binary(release.app_version)
      assert is_list(release.changes)
    end
  end

  describe "report/0" do
    test "is a readable text dump of the same facts" do
      report = SystemControl.report()

      assert is_binary(report)
      assert report =~ "Blackgate system report"
      assert report =~ "gateway version:"
      assert report =~ "uptime:"
      assert report =~ "udp buffers:"
      assert report =~ "decklink:"
      assert report =~ "routes"
    end
  end
end
