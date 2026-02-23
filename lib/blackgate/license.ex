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

    # Load public key
    public_key = load_public_key()

    # Check for existing license in Khepri
    state = %{public_key: public_key}

    case :khepri.get(["license", "key"]) do
      {:ok, license_key} when is_binary(license_key) ->
        Logger.info("License: Found stored license key, verifying...")
        verify_and_store(license_key, public_key)

      _ ->
        Logger.info("License: No license found, checking trial status...")
        init_trial()
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:activate, license_key}, _from, state) do
    case verify_license_key(license_key, state.public_key) do
      {:ok, payload} ->
        # Store in Khepri for persistence
        :khepri.put(["license", "key"], license_key)

        license_data = build_license_data(payload)
        :ets.insert(@table_name, {:license, license_data})

        Logger.info("License: Activated for #{payload["client"]} (#{payload["plan"]})")
        {:reply, {:ok, license_data}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:deactivate, _from, state) do
    :khepri.delete(["license", "key"])
    init_trial()
    Logger.info("License: Deactivated, reverting to trial mode")
    {:reply, :ok, state}
  end

  # ─── Private Functions ───────────────────────────────────────────────────

  defp load_public_key do
    key_path =
      Application.app_dir(:blackgate, "priv/license/public_key.pem")

    case File.read(key_path) do
      {:ok, pem_data} ->
        [entry] = :public_key.pem_decode(pem_data)
        :public_key.pem_entry_decode(entry)

      {:error, reason} ->
        # Try relative path for development
        dev_path = Path.join([File.cwd!(), "priv", "license", "public_key.pem"])

        case File.read(dev_path) do
          {:ok, pem_data} ->
            [entry] = :public_key.pem_decode(pem_data)
            :public_key.pem_entry_decode(entry)

          {:error, _} ->
            Logger.warning("License: Public key not found (#{reason}). License verification disabled.")
            nil
        end
    end
  end

  defp verify_and_store(license_key, public_key) do
    case verify_license_key(license_key, public_key) do
      {:ok, payload} ->
        license_data = build_license_data(payload)
        :ets.insert(@table_name, {:license, license_data})
        Logger.info("License: Valid license for #{payload["client"]} (#{payload["plan"]})")

      {:error, reason} ->
        Logger.warning("License: Stored license invalid (#{reason}), reverting to trial")
        :khepri.delete(["license", "key"])
        init_trial()
    end
  end

  defp verify_license_key(_key, nil) do
    {:error, "License verification not available (public key missing)"}
  end

  defp verify_license_key(license_key, public_key) do
    # Parse: BG-{PLAN}-{base64_payload}.{base64_signature}
    case Regex.run(~r/^BG-([A-Z]{3})-(.+)\.([A-Za-z0-9_-]+)$/, license_key) do
      [_, _plan_prefix, payload_b64, signature_b64] ->
        with {:ok, payload_json} <- Base.url_decode64(payload_b64, padding: false),
             {:ok, payload} <- Jason.decode(payload_json),
             {:ok, signature} <- Base.url_decode64(signature_b64, padding: false) do
          # Verify RSA signature
          is_valid = :public_key.verify(payload_json, :sha256, signature, public_key)

          if is_valid do
            {:ok, payload}
          else
            {:error, "Invalid signature — this key was not signed by the vendor"}
          end
        else
          _ ->
            {:error, "Malformed license key — could not decode payload"}
        end

      nil ->
        {:error, "Invalid license key format"}
    end
  end

  defp build_license_data(payload) do
    expires_at = Date.from_iso8601!(payload["expires_at"])
    today = Date.utc_today()
    days_remaining = Date.diff(expires_at, today)
    is_expired = days_remaining < 0

    %{
      status: :licensed,
      client: payload["client"],
      plan: payload["plan"],
      max_routes: payload["max_routes"],
      issued_at: payload["issued_at"],
      expires_at: payload["expires_at"],
      days_remaining: max(days_remaining, 0),
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
end
