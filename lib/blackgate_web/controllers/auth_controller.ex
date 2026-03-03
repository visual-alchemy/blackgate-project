defmodule BlackgateWeb.AuthController do
  use BlackgateWeb, :controller

  def login(conn, %{"login" => %{"user" => user, "password" => password}}) do
    if verify_credentials(user, password) do
      token = generate_token()

      Cachex.put(Blackgate.Cache, "auth_session:#{token}", user, ttl: :timer.hours(24 * 14))

      conn
      |> put_status(:ok)
      |> json(%{token: token, user: user})
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Invalid username or password"})
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Invalid request format"})
  end

  def update_credentials(conn, %{"current_password" => current_pwd, "new_username" => new_user, "new_password" => new_pwd}) do
    # Assuming standard flow where current username is retrieved from session if available, 
    # but the API allows changing both so user needs to provide their current password properly.
    # Since we only have 1 global user right now, we can read the current user from Khepri.
    current_username =
      case :khepri.get(["auth", "username"]) do
        {:ok, u} when is_binary(u) -> u
        _ -> Application.get_env(:blackgate, :api_auth_username)
      end

    if verify_credentials(current_username, current_pwd) do
      # Store new credentials
      :khepri.put(["auth", "username"], new_user)
      
      new_hash = :crypto.hash(:sha256, new_pwd) |> Base.encode16(case: :lower)
      :khepri.put(["auth", "password_hash"], new_hash)
      
      conn
      |> put_status(:ok)
      |> json(%{message: "Credentials updated successfully"})
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "Invalid current password"})
    end
  end

  def update_credentials(conn, _) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameters (current_password, new_username, new_password)"})
  end

  defp verify_credentials(user, password) do
    require Logger
    
    stored_username =
      case :khepri.get(["auth", "username"]) do
        {:ok, u} when is_binary(u) -> u
        _ -> Application.get_env(:blackgate, :api_auth_username)
      end

    input_hashed = :crypto.hash(:sha256, password) |> Base.encode16(case: :lower)

    stored_password_hash =
      case :khepri.get(["auth", "password_hash"]) do
        {:ok, h} when is_binary(h) -> h
        _ -> 
          val = Application.get_env(:blackgate, :api_auth_password) || ""
          :crypto.hash(:sha256, val) |> Base.encode16(case: :lower)
      end

    Logger.info("Auth Check -> USER: '#{user}' == '#{stored_username}'")
    Logger.info("Auth Check -> PASS: '#{input_hashed}' == '#{stored_password_hash}'")

    Plug.Crypto.secure_compare(user, stored_username || "") and
      Plug.Crypto.secure_compare(input_hashed, stored_password_hash || "")
  end

  defp generate_token do
    :crypto.strong_rand_bytes(30)
    |> Base.url_encode64(padding: false)
  end
end
