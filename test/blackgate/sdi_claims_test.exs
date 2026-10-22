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

    test "a route with no SDI destination is never refused, however busy the card is" do
      # SRT, UDP and RTMP outputs are not the card's business, so a route that has only those must start
      # regardless of who holds every SDI connector.
      busy = [route("a", "A", [0, 1, 2, 3])]

      srt_only = %{
        "id" => "b",
        "name" => "B",
        "destinations" => [
          %{"schema" => "SRT", "schema_options" => %{"device_number" => 0}},
          %{"schema" => "UDP"},
          %{"schema" => "RTMP"}
        ]
      }

      assert SdiClaims.devices_of(srt_only) == []
      assert SdiClaims.conflict(srt_only, busy) == nil
    end

    test "a mixed route is judged only on its SDI destination" do
      # SDI + SRT in one route: the SRT output must never be what refuses the start.
      mixed = with_srt(route("b", "B", [0]))

      conflict = SdiClaims.conflict(mixed, [route("a", "A", [0])])

      assert conflict.label == "SDI 1"

      # ...and with the card free, the same route is fine even though its SRT destination is unchanged.
      assert SdiClaims.conflict(mixed, []) == nil
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

  describe "routes_holding_outputs/2 (what the gate judges against)" do
    # The connector is held by the ENGINE, so the live engine list is the ground truth and the route record only
    # supplies destinations. A registry entry whose engine is gone must not hold anything - on this box that
    # listed RTMP as the holder of SDI 1 and refused the working route on that connector.
    defp lookup_from(routes) do
      fn id ->
        Enum.find_value(routes, {:error, :not_found}, fn r -> if r["id"] == id, do: {:ok, r} end)
      end
    end

    test "a race-free list of the routes that really have an engine" do
      a = route("a", "A", [0])

      assert Blackgate.routes_holding_outputs(["a"], lookup_from([a])) == [a]
    end

    test "a route with no engine holds nothing, even though its record exists" do
      a = route("a", "A", [0])

      # Nothing is passed in, so nothing is running: the record existing is not the question.
      assert Blackgate.routes_holding_outputs([], lookup_from([a])) == []
    end

    test "an engine whose record is gone is kept as a bare id and holds nothing" do
      listed = Blackgate.routes_holding_outputs(["gone"], lookup_from([]))

      assert Enum.map(listed, & &1["id"]) == ["gone"]
      assert SdiClaims.holders(listed) == %{}
      assert SdiClaims.conflict(route("b", "B", [0]), listed) == nil
    end

    test "a record fetched WITHOUT its destinations holds nothing - the failure mode this shape prevents" do
      # Db.get_route/1 omits destinations, and a gate fed those records reports an empty holder map while engines
      # are running, i.e. it allows everything. This pins the failure so the next reader sees which mistake to
      # avoid; the live call uses Db.get_route/2.
      without_destinations = %{"id" => "a", "name" => "A"}

      listed = Blackgate.routes_holding_outputs(["a"], fn _ -> {:ok, without_destinations} end)

      assert SdiClaims.holders(listed) == %{}
      assert SdiClaims.conflict(route("b", "B", [0]), listed) == nil

      with_destinations = route("a", "A", [0])
      listed = Blackgate.routes_holding_outputs(["a"], fn _ -> {:ok, with_destinations} end)

      assert SdiClaims.holders(listed)[0].route_name == "A"
      assert SdiClaims.conflict(route("b", "B", [0]), listed).label == "SDI 1"
    end

    test "does not list one route twice when it reports more than one engine" do
      a = route("a", "A", [0])

      assert length(Blackgate.routes_holding_outputs(["a", "a"], lookup_from([a]))) == 1
    end
  end

  describe "listening ports" do
    # Same class as the card, one layer down: two listeners on one port cannot both bind it, and the engine that
    # loses dies at start with nothing explaining why.

    defp srt(mode, port) do
      %{
        "id" => "s",
        "name" => "SRT",
        "schema" => "SRT",
        "schema_options" => %{"mode" => mode, "localport" => port},
        "destinations" => []
      }
    end

    test "a listener claims its port" do
      assert SdiClaims.listening_ports_of(srt("listener", 17001)) == [17001]
    end

    test "a caller claims nothing - it dials out and binds no port" do
      assert SdiClaims.listening_ports_of(srt("caller", 17001)) == []
    end

    test "a port given as a string is understood" do
      assert SdiClaims.listening_ports_of(srt("listener", "17001")) == [17001]
    end

    test "junk ports are ignored rather than crashing the start path" do
      assert SdiClaims.listening_ports_of(srt("listener", "abc")) == []
      assert SdiClaims.listening_ports_of(srt("listener", nil)) == []
    end

    test "two listeners on one port conflict, and the holder is named" do
      holder = Map.merge(srt("listener", 17001), %{"id" => "a", "name" => "PLTV"})
      other = Map.merge(srt("listener", 17001), %{"id" => "b", "name" => "PLTV 2"})

      claims = SdiClaims.claims_of(other, [holder])

      assert [%{kind: :port, label: "port 17001", held_by: %{route_name: "PLTV"}}] = claims
    end

    test "a listener and a caller on the same number do not conflict" do
      holder = Map.merge(srt("listener", 17001), %{"id" => "a", "name" => "PLTV"})
      caller = Map.merge(srt("caller", 17001), %{"id" => "b", "name" => "Dial out"})

      assert SdiClaims.claims_of(caller, [holder]) == []
    end

    test "a route never conflicts with its own port" do
      route = Map.merge(srt("listener", 17001), %{"id" => "a", "name" => "A"})

      assert SdiClaims.claims_of(route, [route]) == []
    end

    test "both kinds are reported together, so nothing is discovered on the second attempt" do
      holder = route("a", "SPOTV2 (Copy)", [0])

      holder =
        Map.merge(holder, %{
          "schema" => "SRT",
          "schema_options" => %{"mode" => "listener", "localport" => 17001}
        })

      mine = route("b", "B", [0])

      mine =
        Map.merge(mine, %{
          "schema" => "SRT",
          "schema_options" => %{"mode" => "listener", "localport" => 17001}
        })

      kinds = SdiClaims.claims_of(mine, [holder]) |> Enum.map(& &1.kind) |> Enum.sort()

      assert kinds == [:port, :sdi]
    end

    test "port_conflict?/2 is true only for a taken listener port" do
      holder = Map.merge(srt("listener", 17001), %{"id" => "a", "name" => "PLTV"})

      assert SdiClaims.port_conflict?(srt("listener", 17001), [holder])
      refute SdiClaims.port_conflict?(srt("listener", 17002), [holder])
      refute SdiClaims.port_conflict?(srt("caller", 17001), [holder])
    end
  end
end
