defmodule BlackgateWeb.NetworkControllerTest do
  use BlackgateWeb.ConnCase

  alias Blackgate.Db

  @mac "aa:bb:cc:dd:ee:ff"
  @other_mac "aa:bb:cc:dd:ee:00"

  setup do
    # The alias map is one Khepri entry, so a test that writes it must start from a known state and
    # leave it clean. Interface aliases are display labels only; nothing here touches an interface.
    :khepri.delete(["network", "interface_aliases"])
    on_exit(fn -> :khepri.delete(["network", "interface_aliases"]) end)
    :ok
  end

  test "index reports every interface with an alias field", %{conn: conn} do
    conn = get(conn, ~p"/api/network/interfaces")

    assert %{"interfaces" => interfaces} = json_response(conn, 200)
    assert is_list(interfaces)
    assert Enum.all?(interfaces, &Map.has_key?(&1, "alias"))
  end

  test "sets an alias and lists it back", %{conn: conn} do
    conn = put(conn, ~p"/api/network/interfaces/#{@mac}/alias", %{"alias" => "ISP1"})

    assert %{"mac" => @mac, "alias" => "ISP1"} = json_response(conn, 200)
    assert {:ok, aliases} = Db.get_network_interface_aliases()
    assert aliases[@mac] == "ISP1"
  end

  test "a blank alias removes the label again", %{conn: conn} do
    assert %{"alias" => "ISP1"} =
             conn
             |> put(~p"/api/network/interfaces/#{@mac}/alias", %{"alias" => "ISP1"})
             |> json_response(200)

    conn = recycle(conn) |> put(~p"/api/network/interfaces/#{@mac}/alias", %{"alias" => ""})

    assert %{"mac" => @mac, "alias" => nil} = json_response(conn, 200)
    assert {:ok, aliases} = Db.get_network_interface_aliases()
    refute Map.has_key?(aliases, @mac)
  end

  test "normalizes the MAC and trims the label", %{conn: conn} do
    conn =
      put(conn, ~p"/api/network/interfaces/AA:BB:CC:DD:EE:FF/alias", %{"alias" => "  ISP1  "})

    assert %{"mac" => @mac, "alias" => "ISP1"} = json_response(conn, 200)
  end

  test "refuses a bad MAC, an over-long label, and characters that are not a label", %{conn: conn} do
    assert %{"error" => _} =
             conn
             |> put(~p"/api/network/interfaces/not-a-mac/alias", %{"alias" => "ISP1"})
             |> json_response(422)

    too_long = String.duplicate("a", 33)

    assert %{"error" => _} =
             recycle(conn)
             |> put(~p"/api/network/interfaces/#{@mac}/alias", %{"alias" => too_long})
             |> json_response(422)

    assert %{"error" => _} =
             recycle(conn)
             |> put(~p"/api/network/interfaces/#{@mac}/alias", %{"alias" => "bad label!"})
             |> json_response(422)
  end

  test "a label already used by another interface is refused, case-insensitively", %{conn: conn} do
    assert %{} =
             conn
             |> put(~p"/api/network/interfaces/#{@mac}/alias", %{"alias" => "ISP1"})
             |> json_response(200)

    assert %{"error" => _} =
             recycle(conn)
             |> put(~p"/api/network/interfaces/#{@other_mac}/alias", %{"alias" => "isp1"})
             |> json_response(422)
  end

  test "both parameters are required", %{conn: conn} do
    assert %{"error" => _} =
             conn
             |> put(~p"/api/network/interfaces/#{@mac}/alias", %{})
             |> json_response(400)
  end
end
