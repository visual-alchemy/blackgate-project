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

  @doc """
  Re-check the licence against the server now.

  422 rather than 500 when the server cannot be reached: the gateway is fine and the cached licence is still in
  use, so the reason the re-check did not happen is what the operator needs, not an error page.
  """
  def sync(conn, _params) do
    case License.sync() do
      {:ok, license_data} ->
        conn
        |> put_status(:ok)
        |> json(%{data: license_data, message: "Licence re-checked with the server"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})
    end
  end

  @doc "Deactivate current license"
  def deactivate(conn, _params) do
    License.deactivate()

    conn
    |> put_status(:ok)
    |> json(%{message: "License deactivated"})
  end
end
