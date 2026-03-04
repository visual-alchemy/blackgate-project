defmodule Blackgate.License do
  @moduledoc """
  License verification module for Blackgate.

  Validates license keys using RSA public key cryptography.
  Supports trial mode (30 days, 2 routes) for unlicensed installations.
  """

  use GenServer
  require Logger

  @table_name :blackgate_license
  @trial_max_routes 2
  @trial_days 30

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

  @doc "Check if adding a new route is allowed"
  @spec can_start_route?() :: {:ok, :allowed} | {:error, String.t()}
  def can_start_route? do
    license = get_license()

    cond do
      license.expired ->
        {:error, "License expired. Please activate a valid license key."}

      license.status == :trial ->
        active_routes = count_active_routes()

        if active_routes >= @trial_max_routes do
          {:error,
           "Trial limit reached (#{@trial_max_routes} routes). Activate a license for more routes."}
        else
          {:ok, :allowed}
        end

      license.status == :licensed ->
        active_routes = count_active_routes()

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

  # ─── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_args) do
    :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])

    # Check for existing license data in Khepri
    case :khepri.get(["license", "data"]) do
      {:ok, payload} when is_map(payload) ->
        Logger.info("License: Found cached license data for #{payload["client_name"]}, loading...")
        
        # Load immediately to ensure fast boot and offline capability
        license_data = build_license_data(payload)
        :ets.insert(@table_name, {:license, license_data})

        # Spawn an async task to re-verify against the server quietly
        Task.start(fn -> re_verify_license_async(payload["license_key"]) end)

      _ ->
        Logger.info("License: No license found, checking trial status...")
        init_trial()
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

        Logger.info("License: Activated for #{payload["client_name"]} (#{payload["plan_tier"]})")
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
    {:reply, :ok, state}
  end

  # ─── Private Functions ───────────────────────────────────────────────────

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
      parsed_body = if is_binary(response.body) do
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
        
      {:error, reason} ->
        Logger.warning("License: Background verification failed (#{reason}). Keeping cached license active.")
    end
  end

  defp build_license_data(payload) do
    # Handle potentially null expires_at
    expires_at = if payload["expires_at"], do: Date.from_iso8601!(payload["expires_at"] |> String.slice(0, 10)), else: nil
    today = Date.utc_today()
    
    # Calculate days remaining if expiration exists
    {days_remaining, is_expired} = if expires_at do
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
    today = Date.utc_today()
    days_elapsed = Date.diff(today, boot_date)
    days_remaining = max(@trial_days - days_elapsed, 0)
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
      Logger.info("License: Trial mode — #{days_remaining} days remaining (#{@trial_max_routes} routes max)")
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

  defp get_machine_id do

    # 1. Try to read linux machine-id if it exists (for ISO/Docker build)
    case File.read("/etc/machine-id") do
      {:ok, content} ->
        content |> String.trim()

      _ ->
        # 2. Fallback: Check Khepri for a persistent ID
        case :khepri.get(["license", "machine_id"]) do
          {:ok, uid} when is_binary(uid) ->
            uid

          _ ->
            # 3. Generate a new one if still missing
            uid = Base.hex_encode32(:crypto.strong_rand_bytes(10), case: :lower)
            :khepri.put(["license", "machine_id"], uid)
            uid
        end
    end
  end
end

