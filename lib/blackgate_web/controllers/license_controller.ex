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

  @doc "Deactivate current license"
  def deactivate(conn, _params) do
    License.deactivate()

    conn
    |> put_status(:ok)
    |> json(%{message: "License deactivated"})
  end
end
