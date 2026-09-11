defmodule BlackgateWeb.AuthController do
  use BlackgateWeb, :controller

  alias Blackgate.Accounts

  def login(conn, %{"login" => %{"user" => username, "password" => password}}) do
    case Accounts.authenticate(username, password) do
      {:ok, user} ->
        token = generate_token()
        Cachex.put(Blackgate.Cache, "auth_session:#{token}", user, ttl: :timer.hours(24 * 14))
        json(conn, %{token: token, user: user})

      _ ->
        conn |> put_status(:unauthorized) |> json(%{error: "Invalid username or password"})
    end
  end

  def login(conn, _params),
    do: conn |> put_status(:bad_request) |> json(%{error: "Invalid request format"})

  def update_credentials(conn, %{
        "current_password" => current,
        "new_username" => username,
        "new_password" => password
      }) do
    user = conn.assigns.current_user

    with {:ok, _} <- Accounts.update_own_credentials(user["id"], current, username, password) do
      json(conn, %{message: "Credentials updated successfully"})
    else
      {:error, :invalid_credentials} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Invalid current password"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Could not update credentials: #{reason}"})
    end
  end

  def update_credentials(conn, _),
    do: conn |> put_status(:bad_request) |> json(%{error: "Missing credentials"})

  defp generate_token, do: :crypto.strong_rand_bytes(30) |> Base.url_encode64(padding: false)
end
