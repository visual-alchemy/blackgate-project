defmodule Blackgate.OutputClaimsTest do
  use ExUnit.Case, async: true

  alias Blackgate.OutputClaims

  # A listening port is a shared resource, and the gate is deliberately at START time: a route may be configured
  # against a port another route listens on, and whoever is already running keeps it. These tests pin that rule,
  # and in particular that a route which is merely CONFIGURED holds nothing.

  defp srt(mode, port) do
    %{
      "id" => "s",
      "name" => "SRT",
      "schema" => "SRT",
      "schema_options" => %{"mode" => mode, "localport" => port},
      "destinations" => []
    }
  end

  describe "listening_ports_of/1" do
    test "a listener claims its port" do
      assert OutputClaims.listening_ports_of(srt("listener", 17001)) == [17001]
    end

    test "a caller claims nothing - it dials out and binds no port" do
      assert OutputClaims.listening_ports_of(srt("caller", 17001)) == []
    end

    test "a port given as a string is understood" do
      assert OutputClaims.listening_ports_of(srt("listener", "17001")) == [17001]
    end

    test "junk ports are ignored rather than crashing the start path" do
      assert OutputClaims.listening_ports_of(srt("listener", "abc")) == []
      assert OutputClaims.listening_ports_of(srt("listener", nil)) == []
    end
  end

  describe "claims_of/2" do
    test "two listeners on one port conflict, and the holder is named" do
      holder = Map.merge(srt("listener", 17001), %{"id" => "a", "name" => "PLTV"})
      other = Map.merge(srt("listener", 17001), %{"id" => "b", "name" => "PLTV 2"})

      claims = OutputClaims.claims_of(other, [holder])

      assert [%{kind: :port, label: "port 17001", held_by: %{route_name: "PLTV"}}] = claims
    end

    test "a listener and a caller on the same number do not conflict" do
      holder = Map.merge(srt("listener", 17001), %{"id" => "a", "name" => "PLTV"})
      caller = Map.merge(srt("caller", 17001), %{"id" => "b", "name" => "Dial out"})

      assert OutputClaims.claims_of(caller, [holder]) == []
    end

    test "a route never conflicts with its own port" do
      route = Map.merge(srt("listener", 17001), %{"id" => "a", "name" => "A"})

      assert OutputClaims.claims_of(route, [route]) == []
    end

    test "port_conflict?/2 is true only for a taken listener port" do
      holder = Map.merge(srt("listener", 17001), %{"id" => "a", "name" => "PLTV"})

      assert OutputClaims.port_conflict?(srt("listener", 17001), [holder])
      refute OutputClaims.port_conflict?(srt("listener", 17002), [holder])
      refute OutputClaims.port_conflict?(srt("caller", 17001), [holder])
    end
  end

  describe "routes_holding_outputs/2 (what the gate judges against)" do
    # The port is held by the ENGINE, so the live engine list is the ground truth and the route record only
    # supplies its destinations. A registry entry whose engine is gone must not hold anything.
    defp lookup_from(routes) do
      fn id ->
        Enum.find_value(routes, {:error, :not_found}, fn r -> if r["id"] == id, do: {:ok, r} end)
      end
    end

    test "a race-free list of the routes that really have an engine" do
      a = srt("listener", 17001) |> Map.put("id", "a")

      assert Blackgate.routes_holding_outputs(["a"], lookup_from([a])) == [a]
    end

    test "a route with no engine holds nothing, even though its record exists" do
      a = srt("listener", 17001) |> Map.put("id", "a")

      assert Blackgate.routes_holding_outputs([], lookup_from([a])) == []
    end

    test "an engine whose record is gone is kept as a bare id and holds nothing" do
      listed = Blackgate.routes_holding_outputs(["gone"], lookup_from([]))

      assert Enum.map(listed, & &1["id"]) == ["gone"]
      assert OutputClaims.port_holders(listed) == %{}
    end

    test "does not list one route twice when it reports more than one engine" do
      a = srt("listener", 17001) |> Map.put("id", "a")

      assert length(Blackgate.routes_holding_outputs(["a", "a"], lookup_from([a]))) == 1
    end
  end

  describe "a registered-but-dead route" do
    # Measured on the box after the operator stopped a route: its supervisor stayed registered while the
    # RouteHandler child was :undefined, so the next Start answered `{:already_started, pid}` for a route that was
    # not running at all. Both the stop and the start must judge the TREE, not the registration.
    test "a tree with no live handler is not usable" do
      {:ok, sup} =
        Supervisor.start_link(
          [%{id: :idle, start: {Agent, :start_link, [fn -> :ok end]}}],
          strategy: :one_for_one
        )

      refute Blackgate.route_tree_usable?(sup)
      Supervisor.stop(sup)
    end

    test "a tree with a live handler is usable" do
      {:ok, sup} =
        Supervisor.start_link(
          [%{id: {:route_handler, "x"}, start: {Agent, :start_link, [fn -> :ok end]}}],
          strategy: :one_for_one
        )

      assert Blackgate.route_tree_usable?(sup)
      Supervisor.stop(sup)
    end

    test "a dead pid is not usable rather than raising" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      refute Blackgate.route_tree_usable?(pid)
    end
  end
end
