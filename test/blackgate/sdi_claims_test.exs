defmodule Blackgate.SdiClaimsTest do
  use ExUnit.Case, async: true

  alias Blackgate.SdiClaims

  # An SDI connector is a shared resource, and the gate is deliberately at START time: a route may be configured
  # against an output another route uses, and whoever is already running keeps it. These tests pin that rule, and
  # in particular that a route which is merely CONFIGURED holds nothing.

  defp route(id, name, devices) do
    %{
      "id" => id,
      "name" => name,
      "destinations" =>
        Enum.map(devices, fn device ->
          %{"schema" => "SDI", "schema_options" => %{"device_number" => device}}
        end)
    }
  end

  defp with_srt(route) do
    Map.update!(route, "destinations", &(&1 ++ [%{"schema" => "SRT"}]))
  end

  describe "devices_of/1" do
    test "reads the device number off every SDI destination" do
      assert SdiClaims.devices_of(route("a", "A", [0, 2])) == [0, 2]
    end

    test "ignores non-SDI destinations" do
      assert SdiClaims.devices_of(with_srt(route("a", "A", [1]))) == [1]
    end

    test "tolerates a destination with no options, and de-duplicates" do
      route = %{
        "id" => "a",
        "name" => "A",
        "destinations" => [
          %{"schema" => "SDI"},
          %{"schema" => "SDI", "schema_options" => %{}},
          %{"schema" => "SDI", "schema_options" => %{"device_number" => 3}},
          %{"schema" => "SDI", "schema_options" => %{"device_number" => 3}}
        ]
      }

      assert SdiClaims.devices_of(route) == [3]
    end

    test "a route with no destinations asks for nothing" do
      assert SdiClaims.devices_of(%{"id" => "a", "name" => "A"}) == []
    end
  end

  describe "conflict/2" do
    test "a free output is fine" do
      assert SdiClaims.conflict(route("b", "B", [1]), [route("a", "A", [0])]) == nil
    end

    test "a running route on the same output is refused, with the holder named" do
      conflict = SdiClaims.conflict(route("b", "B", [0]), [route("a", "SPOTV2 (Copy)", [0])])

      assert conflict.device == 0
      assert conflict.label == "SDI 1"
      assert conflict.held_by == %{route_id: "a", route_name: "SPOTV2 (Copy)"}
    end

    test "the first occupied output is the one reported" do
      conflict =
        SdiClaims.conflict(route("c", "C", [1, 2]), [
          route("a", "A", [0]),
          route("b", "B", [2])
        ])

      assert conflict.device == 2
      assert conflict.held_by.route_name == "B"
    end

    test "an output held only by a CONFIGURED route is free" do
      # The caller passes only the RUNNING routes, so a route that is stopped holds nothing however its
      # destinations read. This is the reported friction: a stopped route used to grey the output out.
      assert SdiClaims.conflict(route("b", "B", [0]), []) == nil
    end

    test "a route never conflicts with its own claim" do
      # Restarting a route must not be refused by the output it is itself holding.
      assert SdiClaims.conflict(route("a", "A", [0]), [route("a", "A", [0])]) == nil
    end

    test "a running route with no SDI destination blocks nothing" do
      assert SdiClaims.conflict(route("b", "B", [0]), [route("a", "A", [])]) == nil
    end

    test "falls back to the id when the route has no name" do
      unnamed = %{
        "id" => "a",
        "destinations" => [%{"schema" => "SDI", "schema_options" => %{"device_number" => 0}}]
      }

      conflict = SdiClaims.conflict(route("b", "B", [0]), [unnamed])

      assert conflict.held_by.route_name == "a"
    end
  end

  describe "device_label/1" do
    test "names the connector the operator sees, in the card's real order" do
      assert SdiClaims.device_label(0) == "SDI 1"
      assert SdiClaims.device_label(1) == "SDI 3"
      assert SdiClaims.device_label(2) == "SDI 2"
      assert SdiClaims.device_label(3) == "SDI 4"
    end

    test "does not invent a connector for an unknown device" do
      assert SdiClaims.device_label(9) == "SDI device 9"
    end
  end

  describe "holders/1" do
    test "keeps the first route when two somehow hold the same device" do
      holders = SdiClaims.holders([route("a", "A", [0]), route("b", "B", [0])])

      assert holders[0].route_name == "A"
    end

    test "is empty when nothing runs" do
      assert SdiClaims.holders([]) == %{}
    end
  end
end
