defmodule BlackgateWeb.LicenseSyncTest do
  @moduledoc """
  The operator's "ask the server now".

  The heartbeat re-checks every 6 hours and writes what it learns to the log, so a gateway whose licence was
  extended, replaced or revoked on the server can carry on with the old one for the better part of a day, and the
  operator has no way to ask. This endpoint asks.

  The two cases that matter are the two the heartbeat cannot tell apart: no key to re-check (a gateway on the
  trial), and a server that cannot be reached. Neither may take the cached licence away - an appliance that is
  offline keeps streaming on what it last verified, which is the whole point of caching it.
  """

  # `async: false`: the licence record is one Khepri key for the whole node and this file writes to it.
  use BlackgateWeb.ConnCase, async: false

  @table :blackgate_license
  @record_key ["license", "data"]

  setup %{conn: conn} do
    previous = :ets.lookup(@table, :license)
    previous_record = :khepri.get(@record_key)

    on_exit(fn ->
      case previous do
        [{:license, data}] -> :ets.insert(@table, {:license, data})
        [] -> :ets.delete(@table, :license)
      end

      case previous_record do
        {:ok, value} -> :khepri.put(@record_key, value)
        _ -> :khepri.delete(@record_key)
      end
    end)

    %{conn: conn}
  end

  test "a gateway on the trial has no key to re-check, and says so", %{conn: conn} do
    :khepri.delete(@record_key)
    :ets.insert(@table, {:license, %{status: :trial, expired: false, days_remaining: 12}})

    conn = post(conn, ~p"/api/license/sync")

    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "No licence key to re-check"
    assert Blackgate.License.get_license().status == :trial
  end

  test "a server that cannot be reached keeps the cached licence and names the reason", %{
    conn: conn
  } do
    :khepri.put(@record_key, %{
      "license_key" => "BG-TEST-KEY",
      "client_name" => "Test Client",
      "plan_tier" => "pro",
      "max_routes" => 10
    })

    :ets.insert(@table, {:license, %{status: :licensed, expired: false, max_routes: 10}})

    conn = post(conn, ~p"/api/license/sync")

    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "the cached licence is still in use"

    # The cached licence is untouched: the same capacity, still not expired.
    license = Blackgate.License.get_license()
    assert license.status == :licensed
    assert Blackgate.License.capacity_of(license) == 10
  end
end
