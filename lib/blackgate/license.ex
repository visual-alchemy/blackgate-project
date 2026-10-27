defmodule Blackgate.License do
  @moduledoc """
  License verification module for Blackgate.

  Validates license keys using RSA public key cryptography.
  Supports trial mode (30 days, 2 routes) for unlicensed installations.
  """

  use GenServer
  require Logger

  alias Blackgate.EventLog

  @table_name :blackgate_license
  @clock_key ["license", "clock_high_water"]
  @trial_max_routes 2
  @trial_days 30
  # Re-verify license every 6 hours to keep Supabase alive and catch revocations
  @heartbeat_interval :timer.hours(6)

  # ─── Public API ──────────────────────────────────────────────────────────

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @doc "Check if the current license allows operation"
  @spec valid?() :: boolean()
  def valid? do
    case get_license() do
      %{status: :licensed, expired: false} -> true
      %{status: :trial, expired: false} -> true
      _ -> false
    end
  end

  @doc """
  Judge route admission against a caller-supplied count of RUNNING routes.

  The count comes from the caller because the honest one is the live engine set:
  `count_active_routes/0` reads the stored `status`, which can read `started` for a route whose engine is gone.
  Counting a dead route against the licence would refuse a start the operator is entitled to, and missing a live
  one would let a route through. `can_start_route?/0` is kept for callers that only have the record to go on.
  """
  @spec can_admit_route?(non_neg_integer()) :: {:ok, :allowed} | {:error, String.t()}
  def can_admit_route?(active_routes) when is_integer(active_routes) and active_routes >= 0 do
    license = get_license()

    cond do
      license.expired ->
        {:error, "License expired. Please activate a valid license key."}

      license.status == :trial ->
        if active_routes >= @trial_max_routes do
          {:error,
           "Trial limit reached (#{@trial_max_routes} routes). Activate a license for more routes."}
        else
          {:ok, :allowed}
        end

      license.status == :licensed ->
        if active_routes >= license.max_routes do
          {:error,
           "Route limit reached (#{license.max_routes}). Upgrade your license for more routes."}
        else
          {:ok, :allowed}
        end

      true ->
        {:error, "No valid license. Please activate a license key."}
    end
  end

  @doc """
  The route capacity this licence allows right now.

  Zero when the licence does not permit operation at all (expired, unlicensed, or a deactivated key): the
  capacity an enforcement pass measures against is a number, and "no licence" has to be one - not a licence
  that quietly allows everything.
  """
  @spec max_routes_now() :: non_neg_integer()
  def max_routes_now, do: capacity_of(get_license())

  @doc "The capacity a licence payload allows. Zero for anything that permits nothing."
  @spec capacity_of(map()) :: non_neg_integer()
  def capacity_of(%{expired: false, status: :licensed, max_routes: n})
      when is_integer(n) and n >= 0,
      do: n

  def capacity_of(%{expired: false, status: :trial}), do: @trial_max_routes
  def capacity_of(_license), do: 0

  @doc "The trial capacity, so callers do not hard-code it."
  @spec trial_max_routes() :: non_neg_integer()
  def trial_max_routes, do: @trial_max_routes

  @doc "Check if adding a new route is allowed"
  @spec can_start_route?() :: {:ok, :allowed} | {:error, String.t()}
  def can_start_route? do
    can_admit_route?(count_active_routes())
  end

  @doc "Get the current license information"
  @spec get_license() :: map()
  def get_license do
    case :ets.lookup(@table_name, :license) do
      [{:license, data}] -> data
      [] -> %{status: :unlicensed, expired: true}
    end
  end

  @doc "Activate a license key"
  @spec activate(String.t()) :: {:ok, map()} | {:error, String.t()}
  def activate(license_key) do
    GenServer.call(__MODULE__, {:activate, license_key})
  end

  @doc "Deactivate / remove the current license"
  @spec deactivate() :: :ok
  def deactivate do
    GenServer.call(__MODULE__, :deactivate)
  end

  @doc """
  Re-check the licence against the server now, on the operator's request.

  The heartbeat asks every 6 hours, so a key extended, replaced or revoked on the server would otherwise take up
  to that long to reach a running gateway. This is the way to ask now - and the only way to find out whether the
  server is reachable at all, which the heartbeat only records in the log.
  """
  @spec sync() :: {:ok, map()} | {:error, String.t()}
  def sync do
    GenServer.call(__MODULE__, :sync, 60_000)
  end

  @doc """
  The date expiry and trial windows are judged against: today, or the furthest-forward date this gateway has ever
  seen, whichever is later.

  A licence is a date, and a date can be moved: setting the box's clock back would otherwise extend a licence that
  had run out - and give a fresh trial window to a gateway whose trial had passed. The highest date seen is kept
  in `["license", "clock_high_water"]` and used as the floor, so the clock can only ever move the deadline
  forward, never back.
  """
  @spec judgement_date(Date.t()) :: Date.t()
  def judgement_date(today \\ Date.utc_today()) do
    case :khepri.get(@clock_key) do
      {:ok, iso} when is_binary(iso) ->
        case Date.from_iso8601(iso) do
          {:ok, seen} ->
            if Date.compare(today, seen) == :lt do
              seen
            else
              store_floor(today)
              today
            end

          _ ->
            store_floor(today)
            today
        end

      _ ->
        store_floor(today)
        today
    end
  rescue
    # A licence judgment must not fail because the clock floor could not be stored: today is the safe answer.
    _ -> today
  end

  # ─── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_args) do
    :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])

    # Check for existing license data in Khepri
    case :khepri.get(["license", "data"]) do
      {:ok, payload} when is_map(payload) ->
        Logger.info(
          "License: Found cached license data for #{payload["client_name"]}, loading..."
        )

        # Load immediately to ensure fast boot and offline capability
        license_data = build_license_data(payload)
        :ets.insert(@table_name, {:license, license_data})

        # Spawn an async task to re-verify against the server quietly
        Task.start(fn -> re_verify_license_async(payload["license_key"]) end)

        # Schedule periodic heartbeat
        schedule_heartbeat()

      _ ->
        Logger.info("License: No license found, checking trial status...")
        init_trial()
        warn_missing_license()
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:activate, license_key}, _from, state) do
    case verify_license_with_server(license_key) do
      {:ok, payload} ->
        # Store full payload in Khepri for offline persistence
        :khepri.put(["license", "data"], payload)

        license_data = build_license_data(payload)
        :ets.insert(@table_name, {:license, license_data})

        # Start heartbeat on fresh activation
        schedule_heartbeat()

        Logger.info("License: Activated for #{payload["client_name"]} (#{payload["plan_tier"]})")

        # A new key can cover FEWER routes than are running (a downgrade, or a licence re-issued after a return):
        # the pass makes the running set match what was just activated instead of leaving the old engines up.
        Blackgate.LicenseEnforcer.enforce_soon()

        {:reply, {:ok, license_data}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:deactivate, _from, state) do
    :khepri.delete(["license", "data"])
    init_trial()
    Logger.info("License: Deactivated, reverting to trial mode")

    # The trial covers 2 routes (and none once its window has passed), so a deactivation can leave the box running
    # more than it now covers. Make the running set match the state the operator just chose.
    Blackgate.LicenseEnforcer.enforce_soon()

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    case :khepri.get(["license", "data"]) do
      {:ok, payload} when is_map(payload) ->
        case verify_license_with_server(payload["license_key"]) do
          {:ok, fresh} ->
            :khepri.put(["license", "data"], fresh)
            license_data = build_license_data(fresh)
            :ets.insert(@table_name, {:license, license_data})
            Blackgate.LicenseEnforcer.enforce_soon()
            Logger.info("License: Re-verified with the server on request")
            {:reply, {:ok, license_data}, state}

          # The cached licence stays in use: a server that is unreachable or down must not take an appliance's
          # entitlement away. The answer says which of the two happened instead of leaving the operator to guess.
          {:error, reason} ->
            {:reply, {:error, "#{reason} (the cached licence is still in use)"}, state}
        end

      _ ->
        {:reply, {:error, "No licence key to re-check: this gateway is running on the trial"},
         state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    case :khepri.get(["license", "data"]) do
      {:ok, payload} when is_map(payload) ->
        Logger.info("License: Running periodic heartbeat verification...")
        re_verify_license_async(payload["license_key"])

      _ ->
        Logger.debug("License: Heartbeat skipped — no active license")
    end

    schedule_heartbeat()
    {:noreply, state}
  end

  # ─── Private Functions ───────────────────────────────────────────────────

  defp store_floor(date), do: :khepri.put(@clock_key, Date.to_iso8601(date))

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end

  defp verify_license_with_server(license_key) do
    server_url = Application.get_env(:blackgate, :license_server_url, "http://localhost:3000")

    headers = [
      {"content-type", "application/json"}
    ]

    body = %{
      license_key: license_key,
      machine_id: Blackgate.MachineId.get()
    }

    try do
      response = Req.post!("#{server_url}/api/validate", headers: headers, json: body)

      # Vercel NextJS might sometimes return text/plain for error responses
      parsed_body =
        if is_binary(response.body) do
          case Jason.decode(response.body) do
            {:ok, decoded} -> decoded
            _ -> %{}
          end
        else
          response.body || %{}
        end

      cond do
        response.status == 200 && parsed_body["valid"] == true ->
          {:ok, parsed_body["license"]}

        response.status in [401, 403, 404] ->
          error_msg = parsed_body["error"] || "Verification failed"
          {:error, error_msg}

        true ->
          {:error, "Unexpected response from license server"}
      end
    rescue
      e ->
        Logger.error("Failed to connect to license server: #{inspect(e)}")
        {:error, "Could not reach license server for verification. Are you online?"}
    end
  end

  defp re_verify_license_async(license_key) do
    case verify_license_with_server(license_key) do
      {:ok, payload} ->
        Logger.debug("License: Background verification successful")
        # Update cache in case expiration dates or tiers changed
        :khepri.put(["license", "data"], payload)
        license_data = build_license_data(payload)
        :ets.insert(@table_name, {:license, license_data})

        # A re-verification is where a key that was revoked, expired or moved to a smaller plan shows up, and it
        # runs quietly in the background: without this the change would only take effect on the next tick.
        Blackgate.LicenseEnforcer.enforce_soon()

      {:error, reason} ->
        Logger.warning(
          "License: Background verification failed (#{reason}). Keeping cached license active."
        )
    end
  end

  defp build_license_data(payload) do
    # Handle potentially null expires_at
    expires_at =
      if payload["expires_at"],
        do: Date.from_iso8601!(payload["expires_at"] |> String.slice(0, 10)),
        else: nil

    today = judgement_date()

    # Calculate days remaining if expiration exists
    {days_remaining, is_expired} =
      if expires_at do
        remaining = Date.diff(expires_at, today)
        {max(remaining, 0), remaining < 0}
      else
        # Lifetime license
        {9999, false}
      end

    %{
      status: :licensed,
      client: payload["client_name"],
      plan: payload["plan_tier"],
      max_routes: payload["max_routes"],
      issued_at: payload["created_at"] |> String.slice(0, 10),
      expires_at: if(expires_at, do: Date.to_iso8601(expires_at), else: nil),
      days_remaining: days_remaining,
      expired: is_expired
    }
  end

  # A gateway that should hold a licence but does not - its store lost the record, or a key was never activated -
  # looks exactly like one that was never licensed: the dashboard shows a trial. That is a true statement and an
  # easy one to walk past, so it is said as an event the Events tab carries, with the two different consequences
  # spelled out: a trial with days left still streams, a trial whose window has passed starts nothing.
  defp warn_missing_license do
    case get_license() do
      %{status: :trial, expired: true} ->
        EventLog.log(
          :critical,
          "license_missing",
          "No licence found and the trial window has passed: no route can be started until a licence is activated",
          %{}
        )

      %{status: :trial} = trial ->
        EventLog.log(
          :warning,
          "license_missing",
          "No licence found: running on the trial (#{trial[:days_remaining]} days left, " <>
            "#{@trial_max_routes} routes)",
          %{days_remaining: trial[:days_remaining], max_routes: @trial_max_routes}
        )

      _ ->
        :ok
    end
  end

  defp init_trial do
    # Get or set the first boot timestamp
    first_boot =
      case :khepri.get(["license", "first_boot"]) do
        {:ok, timestamp} when is_binary(timestamp) ->
          timestamp

        _ ->
          timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
          :khepri.put(["license", "first_boot"], timestamp)
          timestamp
      end

    # Calculate trial remaining
    {:ok, boot_dt, _} = DateTime.from_iso8601(first_boot)
    boot_date = DateTime.to_date(boot_dt)
    today = judgement_date()
    days_elapsed = Date.diff(today, boot_date)

    # Never more than a full window: a first-boot stamp in the future (a clock that was set forward, then
    # corrected) would otherwise compute a negative elapsed time and hand out a longer trial than the product
    # allows.
    days_remaining = (@trial_days - days_elapsed) |> min(@trial_days) |> max(0)
    is_expired = days_remaining <= 0

    trial_data = %{
      status: :trial,
      client: "Trial",
      plan: "trial",
      max_routes: @trial_max_routes,
      issued_at: Date.to_iso8601(boot_date),
      expires_at: Date.to_iso8601(Date.add(boot_date, @trial_days)),
      days_remaining: days_remaining,
      expired: is_expired
    }

    :ets.insert(@table_name, {:license, trial_data})

    if is_expired do
      Logger.warning("License: Trial period has expired")
    else
      Logger.info(
        "License: Trial mode — #{days_remaining} days remaining (#{@trial_max_routes} routes max)"
      )
    end
  end

  defp count_active_routes do
    case Blackgate.Db.get_all_routes() do
      {:ok, routes} ->
        routes
        |> Enum.count(fn route ->
          route["status"] == "started" || route["status"] == "running"
        end)

      _ ->
        0
    end
  end
end
