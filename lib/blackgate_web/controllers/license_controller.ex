defmodule BlackgateWeb.LicenseController do
  use BlackgateWeb, :controller

  alias Blackgate.License

  @doc "Get current license status"
  def show(conn, _params) do
    license = license_status()

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
        |> json(%{data: license_status(), message: "License synchronized"})

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(:too_many_requests)
        |> json(%{
          error: "License was synced recently. Try again shortly.",
          retry_after_seconds: retry_after
        })

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
  def activate(conn, %{"license_key" => license_key}) do
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

  def activate(conn, %{"key" => license_key}), do: activate(conn, %{"license_key" => license_key})

  def activate(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing 'license_key' parameter"})
  end

  @doc "Deactivate current license"
  def deactivate(conn, _params) do
    License.deactivate()

    conn
    |> put_status(:ok)
    |> json(%{message: "License deactivated"})
  end

  defp license_status do
    License.get_license() |> Map.put(:active_routes, length(Blackgate.running_routes()))
  end
end
