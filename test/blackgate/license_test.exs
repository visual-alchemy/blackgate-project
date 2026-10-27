defmodule Blackgate.LicenseTest do
  @moduledoc """
  The licence itself: what state permits what, and the thing that keeps a local entitlement honest.

  The capacity table is pinned here because every refusal the operator sees is a sentence built from it - the gate
  (`can_admit_route?/1`) and the enforcement pass (`max_routes_now/0`) both read it, and a licence state that
  quietly meant "unlimited" would make the product's whole enforcement story untrue.

  The clock floor is pinned because a licence is a date and a date can be moved: rolling the box's clock back must
  not extend a licence or hand out a fresh trial window.
  """

  # `async: false`: the licence state is one ETS entry and a Khepri key for the whole node.
  use ExUnit.Case, async: false

  alias Blackgate.License

  @table :blackgate_license
  @record_key ["license", "data"]
  @clock_key ["license", "clock_high_water"]

  setup do
    previous = :ets.lookup(@table, :license)
    previous_record = :khepri.get(@record_key)
    previous_clock = :khepri.get(@clock_key)

    on_exit(fn ->
      case previous do
        [{:license, data}] -> :ets.insert(@table, {:license, data})
        [] -> :ets.delete(@table, :license)
      end

      restore_key(@record_key, previous_record)
      restore_key(@clock_key, previous_clock)
    end)

    :ok
  end

  defp restore_key(key, {:ok, value}), do: :khepri.put(key, value)
  defp restore_key(key, _not_found), do: :khepri.delete(key)

  test "a licence covers the routes it names, and nothing when it permits nothing" do
    assert License.capacity_of(%{status: :licensed, expired: false, max_routes: 10}) == 10
    assert License.capacity_of(%{status: :licensed, expired: false, max_routes: 0}) == 0
    assert License.capacity_of(%{status: :trial, expired: false}) == License.trial_max_routes()

    # Expired, unlicensed, or a state that is not a licence at all: no routes. This is the half that used to be
    # missing - an unrecognised state read as "allowed" everywhere but the Start button.
    assert License.capacity_of(%{status: :licensed, expired: true, max_routes: 10}) == 0
    assert License.capacity_of(%{status: :unlicensed, expired: true}) == 0
    assert License.capacity_of(%{status: :suspended, expired: false, max_routes: 10}) == 0
    assert License.capacity_of(%{}) == 0
  end

  test "the clock floor keeps a licence expired even when the clock is moved back" do
    :khepri.delete(@clock_key)

    today = Date.utc_today()
    assert License.judgement_date(today) == today

    # The furthest-forward date seen is kept, so a later judgment on an earlier day cannot go back before it.
    ahead = Date.add(today, 30)
    assert License.judgement_date(ahead) == ahead
    assert License.judgement_date(today) == ahead
    assert License.judgement_date(Date.add(today, -365)) == ahead
  end

  test "the floor follows the clock when the clock moves forward" do
    :khepri.delete(@clock_key)

    today = Date.utc_today()
    assert License.judgement_date(today) == today

    later = Date.add(today, 5)
    assert License.judgement_date(later) == later
    # Stored once, and the same answer afterwards: the floor never goes backwards.
    assert License.judgement_date(later) == later
    assert License.judgement_date(today) == later
  end
end
