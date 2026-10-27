defmodule BlackgateWeb.LicenseController do
  use BlackgateWeb, :controller

  alias Blackgate.License

  @doc "Get current license status"
  def show(conn, _params) do
    license = License.get_license()

    conn
    |> put_status(:ok)
    |> json(%{data: license})
  end

  @doc "Immediately synchronize the activated license with the license server"
  def sync(conn, _params) do
    case License.sync_now() do
      {:ok, _license} ->
        conn
        |> put_status(:ok)
        |> json(%{data: License.get_license(), message: "License synchronized"})

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(:too_many_requests)
        |> json(%{
          error: "License was synced recently. Try again shortly.",
          retry_after_seconds: retry_after
        })

      # The cached entitlement, the last verification time and the original offline deadline all survive a failed
      # sync: a network problem must not cost a licensed appliance its license. The browser is told the state was
      # preserved rather than left to guess from a bare 503.
      {:error, :unreachable, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Cannot reach license server. Existing license state was preserved."})

      {:error, _kind, reason} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: reason})
    end
  end

  @doc "Activate a license key"
  def activate(conn, %{"key" => license_key}) do
    case License.activate(license_key) do
      {:ok, license_data} ->
        conn
        |> put_status(:ok)
        |> json(%{data: license_data, message: "License activated successfully"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})
    end
  end

  def activate(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing 'key' parameter"})
  end

  @doc "Deactivate current license"
  def deactivate(conn, _params) do
    License.deactivate()

    conn
    |> put_status(:ok)
    |> json(%{message: "License deactivated"})
  end
end
