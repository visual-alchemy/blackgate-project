defmodule Blackgate.License do
  @moduledoc "Local entitlement deadlines, durable offline grace, and remote validation."
  use GenServer
  require Logger
  @table :blackgate_license
  @path ["license", "enforcement_v1"]
  @heartbeat :timer.hours(6)

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)
  def activate(key), do: GenServer.call(__MODULE__, {:activate, key}, 30_000)
  def deactivate, do: GenServer.call(__MODULE__, :deactivate)
  def valid?, do: not get_license().expired

  def utc_now do
    clock = Application.get_env(:blackgate, :license_clock, DateTime)
    clock.utc_now() |> DateTime.to_unix()
  end

  defp monotonic, do: System.monotonic_time(:second)

  def get_license do
    case :ets.lookup(@table, :license) do
      [{:license, cache, wall, mono}] ->
        evaluate(cache, max(utc_now(), wall + max(monotonic() - mono, 0)))

      _ ->
        blocked("License state unavailable")
    end
  rescue
    ArgumentError -> blocked("License state unavailable")
  end

  @doc false
  def evaluate(cache, now) do
    expiry = Map.get(cache, :deadline)
    offline = Map.get(cache, :offline_deadline)
    status = Map.get(cache, :status, :unlicensed)

    reason =
      cond do
        status not in [:trial, :licensed] ->
          Map.get(cache, :reason, "No valid license")

        is_integer(expiry) and now >= expiry ->
          "License expired. Please activate a valid license key."

        is_integer(offline) and now >= offline ->
          "Offline grace expired. Connect to license server."

        true ->
          nil
      end

    %{
      status: status,
      expired: reason != nil,
      reason: reason,
      client: Map.get(cache, :client, "Unlicensed"),
      plan: Map.get(cache, :plan, "none"),
      max_routes: Map.get(cache, :max_routes, 0),
      issued_at: Map.get(cache, :issued_at),
      expires_at: iso(expiry),
      offline_deadline: iso(offline),
      last_verified_at: iso(Map.get(cache, :verified_at)),
      days_remaining:
        if(is_integer(expiry), do: max(div(expiry - now + 86_399, 86_400), 0), else: 9999),
      verification: Map.get(cache, :verification, "none")
    }
  end

  defp blocked(reason), do: %{status: :unlicensed, expired: true, reason: reason, max_routes: 0}
  defp iso(nil), do: nil
  defp iso(seconds), do: seconds |> DateTime.from_unix!() |> DateTime.to_iso8601()

  def can_start_route?(id \\ nil) do
    license = get_license()
    active = Blackgate.running_routes()

    cond do
      license.expired ->
        {:error, license.reason}

      Enum.any?(active, &(&1.id == id)) ->
        {:ok, :allowed}

      length(active) >= license.max_routes ->
        {:error, "Route limit reached (#{license.max_routes})."}

      true ->
        {:ok, :allowed}
    end
  end

  def can_create_route? do
    license = get_license()

    with false <- license.expired, {:ok, routes} <- Blackgate.Db.get_all_routes() do
      if license.status == :trial and length(routes) >= 2 do
        creation_error("Trial route limit reached (2). Activate a license for more routes.")
      else
        {:ok, :allowed}
      end
    else
      true -> creation_error(license.reason)
      _ -> creation_error("Cannot verify saved route count")
    end
  end

  defp creation_error(reason), do: {:error, {:route_creation_not_allowed, reason}}

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

    cache =
      case :khepri.get(@path) do
        {:ok, %{status: _} = stored} -> stored
        {:error, {:khepri, :node_not_found, _}} -> migrate(utc_now())
        _ -> raise "Cannot load license enforcement state"
      end

    state = publish(%{cache: cache, generation: make_ref(), checking: false})
    send(self(), :heartbeat)
    Process.send_after(self(), :checkpoint, 60_000)
    {:ok, state}
  end

  defp migrate(now) do
    case :khepri.get(["license", "data"]) do
      {:ok, payload} when is_map(payload) ->
        case from_payload(payload, now) do
          {:ok, cache} ->
            Map.merge(cache, %{
              offline_deadline: now + 86_400,
              verified_at: nil,
              verification: "legacy_migration",
              ever_licensed: true
            })

          _ ->
            %{
              status: :revoked,
              ever_licensed: true,
              reason: "Invalid cached license; activate again"
            }
        end

      {:error, {:khepri, :node_not_found, _}} ->
        first =
          case :khepri.get(["license", "first_boot"]) do
            {:ok, value} ->
              parse_timestamp(value)

            {:error, {:khepri, :node_not_found, _}} ->
              :ok = :khepri.put(["license", "first_boot"], iso(now))
              {:ok, now}

            _ ->
              :error
          end

        case first do
          {:ok, timestamp} ->
            %{
              status: :trial,
              client: "Trial",
              plan: "trial",
              max_routes: 2,
              deadline: timestamp + 30 * 86_400,
              issued_at: iso(timestamp),
              ever_licensed: false
            }

          _ ->
            %{status: :revoked, reason: "Invalid trial state"}
        end

      _ ->
        raise "Cannot load legacy license state"
    end
  end

  @impl true
  def handle_call({:activate, key}, _from, state) do
    case verify(key) do
      {:ok, payload} ->
        case from_payload(Map.put(payload, "license_key", key), effective_now(state)) do
          {:ok, cache} ->
            state = publish(%{state | cache: cache, generation: make_ref(), checking: false})
            notify_enforcer()
            {:reply, {:ok, get_license()}, state}

          _ ->
            {:reply, {:error, "Invalid license response"}, state}
        end

      {:error, _, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:deactivate, _from, state) do
    cache =
      if Map.get(state.cache, :ever_licensed, false) do
        %{
          status: :unlicensed,
          ever_licensed: true,
          reason: "License deactivated. Activate a valid license."
        }
      else
        state.cache
      end

    state = publish(%{state | cache: cache, generation: make_ref(), checking: false})
    :khepri.delete(["license", "data"])
    notify_enforcer()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, @heartbeat)
    {:noreply, begin_verification(state)}
  end

  def handle_info({:verified, generation, result}, %{generation: generation} = state) do
    state = %{state | checking: false}

    state =
      case result do
        {:ok, payload} ->
          case from_payload(
                 Map.put(payload, "license_key", state.cache.key),
                 effective_now(state)
               ) do
            {:ok, cache} -> publish(%{state | cache: cache})
            _ -> revoke(state, "Invalid license response")
          end

        {:error, :revoked, reason} ->
          revoke(state, reason)

        {:error, :unreachable, reason} ->
          Logger.warning(
            "License validation unavailable: #{reason}; keeping original offline deadline"
          )

          state
      end

    notify_enforcer()
    {:noreply, state}
  end

  def handle_info({:verified, _, _}, state), do: {:noreply, state}

  def handle_info(:checkpoint, state) do
    Process.send_after(self(), :checkpoint, 60_000)
    {:noreply, publish(state)}
  end

  defp begin_verification(%{checking: true} = state), do: state

  defp begin_verification(state) do
    if is_binary(Map.get(state.cache, :key)) do
      parent = self()
      key = state.cache.key
      generation = state.generation
      Task.start(fn -> send(parent, {:verified, generation, verify(key)}) end)
      %{state | checking: true}
    else
      state
    end
  end

  defp revoke(state, reason) do
    publish(%{state | cache: Map.merge(state.cache, %{status: :revoked, reason: reason})})
  end

  defp effective_now(state) do
    floor = Map.get(state.cache, :last_seen_at, 0)
    elapsed = max(monotonic() - Map.get(state, :mono, monotonic()), 0)
    max(utc_now(), floor + elapsed)
  end

  defp publish(state) do
    previous_floor =
      case :ets.lookup(@table, :license) do
        [{:license, _, wall, mono}] -> wall + max(monotonic() - mono, 0)
        _ -> 0
      end

    now = max(effective_now(state), previous_floor)
    cache = Map.put(state.cache, :last_seen_at, now)
    :ok = :khepri.put(@path, cache)
    :ets.insert(@table, {:license, cache, now, monotonic()})
    %{state | cache: cache} |> Map.put(:mono, monotonic())
  end

  defp notify_enforcer do
    if pid = Process.whereis(Blackgate.LicenseEnforcer), do: send(pid, :enforce)
  end

  defp verify(key) do
    url = Application.get_env(:blackgate, :license_server_url, "http://localhost:3000")

    try do
      response =
        Req.post!("#{url}/api/validate",
          json: %{license_key: key, machine_id: Blackgate.MachineId.get()},
          receive_timeout: 10_000,
          retry: false
        )

      body = if is_binary(response.body), do: Jason.decode!(response.body), else: response.body

      cond do
        response.status == 200 and body["valid"] == true and is_map(body["license"]) ->
          {:ok, body["license"]}

        response.status in [401, 403, 404] ->
          {:error, :revoked, body["error"] || "License rejected"}

        true ->
          {:error, :unreachable, "Unexpected server response"}
      end
    rescue
      _ -> {:error, :unreachable, "Cannot reach license server"}
    end
  end

  defp from_payload(payload, now) do
    with max_routes when is_integer(max_routes) and max_routes > 0 <- payload["max_routes"],
         {:ok, deadline} <- parse_expiry(payload["expires_at"]),
         key when is_binary(key) and byte_size(key) > 0 <- payload["license_key"] do
      {:ok,
       %{
         status: :licensed,
         client: payload["client_name"],
         plan: payload["plan_tier"],
         max_routes: max_routes,
         deadline: deadline,
         issued_at: payload["created_at"],
         key: key,
         ever_licensed: true,
         verified_at: now,
         verification: "server_validated",
         offline_deadline: now + Application.get_env(:blackgate, :offline_grace_days, 30) * 86_400
       }}
    else
      _ -> :error
    end
  end

  defp parse_expiry(nil), do: {:ok, nil}
  # Preserve legacy date-only validity through the end of that UTC day.
  defp parse_expiry(<<_::binary-size(10)>> = date) do
    with {:ok, d} <- Date.from_iso8601(date) do
      {:ok, DateTime.new!(Date.add(d, 1), ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()}
    end
  end

  defp parse_expiry(value), do: parse_timestamp(value)

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, DateTime.to_unix(dt)}
      _ -> :error
    end
  end

  defp parse_timestamp(_), do: :error
end
