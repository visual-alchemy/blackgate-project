defmodule Blackgate.Accounts do
  @moduledoc false

  @iterations 600_000
  @roles ["admin", "operator"]

  def bootstrap_admin do
    case list_users() do
      {:ok, []} ->
        {username, password_hash} = legacy_credentials()
        now = DateTime.utc_now()

        user = %{
          "id" => UUID.uuid4(),
          "username" => username,
          "password_hash" => password_hash,
          "role" => "admin",
          "enabled" => true,
          "created_at" => now,
          "updated_at" => now,
          "last_login_at" => nil
        }

        with :ok <- :khepri.put(["users", user["id"]], user), do: {:ok, [public_user(user)]}

      {:ok, users} ->
        {:ok, users}

      error ->
        error
    end
  end

  def authenticate(username, password) when is_binary(username) and is_binary(password) do
    with {:ok, _} <- bootstrap_admin(),
         {:ok, user} <- get_by_username(username),
         true <-
           user["enabled"] != false and verify_password(password, user["password_hash"] || "") do
      user = upgrade_legacy_hash(user, password)
      {:ok, public_user(user)}
    else
      false -> {:error, :invalid_credentials}
      {:ok, nil} -> {:error, :invalid_credentials}
      error -> error
    end
  end

  def list_users do
    case :khepri.get_many("users/*") do
      {:ok, users} ->
        {:ok,
         users
         |> Enum.map(fn {_path, user} -> public_user(user) end)
         |> Enum.sort_by(& &1["username"])}

      error ->
        error
    end
  end

  def create_user(%{"username" => username, "password" => password, "role" => role}) do
    with :ok <- valid_username(username),
         :ok <- valid_password(password),
         :ok <- valid_role(role) do
      :global.trans({__MODULE__, :users}, fn ->
        case get_by_username(username) do
          {:ok, nil} ->
            now = DateTime.utc_now()

            user = %{
              "id" => UUID.uuid4(),
              "username" => username,
              "password_hash" => password_hash(password),
              "role" => role,
              "enabled" => true,
              "created_at" => now,
              "updated_at" => now,
              "last_login_at" => nil
            }

            with :ok <- :khepri.put(["users", user["id"]], user), do: {:ok, public_user(user)}

          {:ok, _} ->
            {:error, :username_taken}

          error ->
            error
        end
      end)
    end
  end

  def update_user(id, attrs) when is_binary(id) and is_map(attrs) do
    :global.trans({__MODULE__, :users}, fn ->
      with {:ok, user} <- get_user(id),
           :ok <- validate_update(attrs),
           :ok <- ensure_username_available(id, Map.get(attrs, "username")) do
        updated =
          user
          |> Map.merge(Map.take(attrs, ["username", "role", "enabled"]))
          |> Map.put("updated_at", DateTime.utc_now())
          |> maybe_change_password(Map.get(attrs, "password"))

        with :ok <- ensure_not_last_admin_change(user, updated),
             :ok <- :khepri.put(["users", id], updated) do
          {:ok, public_user(updated)}
        end
      end
    end)
  end

  def delete_user(id) when is_binary(id) do
    :global.trans({__MODULE__, :users}, fn ->
      with {:ok, user} <- get_user(id),
           :ok <- ensure_not_last_admin(user) do
        :khepri.delete(["users", id])
      end
    end)
  end

  def change_password(id, current_password, new_password) do
    with {:ok, user} <- get_user(id),
         true <- verify_password(current_password, user["password_hash"]),
         :ok <- valid_password(new_password),
         {:ok, public} <- update_user(id, %{"password" => new_password}) do
      {:ok, public}
    else
      false -> {:error, :invalid_credentials}
      error -> error
    end
  end

  def update_own_credentials(id, current_password, username, new_password) do
    :global.trans({__MODULE__, :users}, fn ->
      with {:ok, user} <- get_user(id),
           true <- verify_password(current_password, user["password_hash"]),
           :ok <- valid_username(username),
           :ok <- valid_password(new_password),
           :ok <- ensure_username_available(id, username) do
        updated =
          user
          |> Map.put("username", username)
          |> Map.put("password_hash", password_hash(new_password))
          |> Map.put("updated_at", DateTime.utc_now())

        with :ok <- :khepri.put(["users", id], updated), do: {:ok, public_user(updated)}
      else
        false -> {:error, :invalid_credentials}
        error -> error
      end
    end)
  end

  def session_user(id) when is_binary(id) do
    with {:ok, user} <- get_user(id),
         true <- user["enabled"] != false do
      {:ok, public_user(user)}
    else
      false -> {:error, :disabled}
      error -> error
    end
  end

  def get_user(id) do
    case :khepri.get(["users", id]) do
      {:ok, user} -> {:ok, user}
      {:error, {:khepri, :node_not_found, _}} -> {:error, :not_found}
      error -> error
    end
  end

  defp get_by_username(username) do
    with {:ok, users} <- :khepri.get_many("users/*") do
      {:ok,
       Enum.find_value(users, fn {_path, user} -> if user["username"] == username, do: user end)}
    end
  end

  defp legacy_credentials do
    username = legacy_value("username", Application.get_env(:blackgate, :api_auth_username))

    password_hash =
      case :khepri.get(["auth", "password_hash"]) do
        {:ok, value} when is_binary(value) ->
          "legacy_sha256$#{value}"

        _ ->
          password = Application.get_env(:blackgate, :api_auth_password) || ""
          "legacy_sha256$#{:crypto.hash(:sha256, password) |> Base.encode16(case: :lower)}"
      end

    {username, password_hash}
  end

  defp legacy_value(key, fallback) do
    case :khepri.get(["auth", key]) do
      {:ok, value} when is_binary(value) -> value
      _ -> fallback || "admin"
    end
  end

  defp valid_username(value) when is_binary(value) and byte_size(value) in 3..64 do
    if value =~ ~r/\A[a-zA-Z0-9._-]+\z/, do: :ok, else: {:error, :invalid_username}
  end

  defp valid_username(_), do: {:error, :invalid_username}
  defp valid_password(value) when is_binary(value) and byte_size(value) >= 12, do: :ok
  defp valid_password(_), do: {:error, :invalid_password}
  defp valid_role(role) when role in @roles, do: :ok
  defp valid_role(_), do: {:error, :invalid_role}

  defp validate_update(attrs) do
    with :ok <-
           if(Map.has_key?(attrs, "username"), do: valid_username(attrs["username"]), else: :ok),
         :ok <- if(Map.has_key?(attrs, "role"), do: valid_role(attrs["role"]), else: :ok),
         :ok <-
           if(Map.has_key?(attrs, "password"), do: valid_password(attrs["password"]), else: :ok),
         true <- !Map.has_key?(attrs, "enabled") or is_boolean(attrs["enabled"]) do
      :ok
    else
      false -> {:error, :invalid_enabled}
      error -> error
    end
  end

  defp ensure_username_available(_id, nil), do: :ok

  defp ensure_username_available(id, username) do
    with {:ok, user} <- get_by_username(username),
         true <- is_nil(user) or user["id"] == id do
      :ok
    else
      false -> {:error, :username_taken}
      error -> error
    end
  end

  defp ensure_not_last_admin(%{"role" => "admin", "enabled" => true}) do
    with {:ok, users} <- list_users(),
         true <- Enum.count(users, &(&1["role"] == "admin" and &1["enabled"])) > 1 do
      :ok
    else
      false -> {:error, :last_admin}
      error -> error
    end
  end

  defp ensure_not_last_admin(_), do: :ok

  defp ensure_not_last_admin_change(
         %{"role" => "admin", "enabled" => true},
         %{"role" => role, "enabled" => enabled}
       )
       when role != "admin" or enabled != true do
    with {:ok, users} <- list_users(),
         true <- Enum.count(users, &(&1["role"] == "admin" and &1["enabled"])) > 1 do
      :ok
    else
      false -> {:error, :last_admin}
      error -> error
    end
  end

  defp ensure_not_last_admin_change(_, _), do: :ok
  defp maybe_change_password(user, nil), do: user

  defp maybe_change_password(user, password),
    do: Map.put(user, "password_hash", password_hash(password))

  defp password_hash(password) do
    salt = :crypto.strong_rand_bytes(16)
    hash = :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, 32)
    "pbkdf2_sha256$#{@iterations}$#{Base.encode64(salt)}$#{Base.encode64(hash)}"
  end

  defp verify_password(password, "pbkdf2_sha256$" <> encoded) do
    case String.split(encoded, "$", parts: 3) do
      [iterations, salt, expected] ->
        with {count, ""} <- Integer.parse(iterations),
             {:ok, salt} <- Base.decode64(salt),
             {:ok, expected} <- Base.decode64(expected) do
          :crypto.pbkdf2_hmac(:sha256, password, salt, count, byte_size(expected))
          |> Plug.Crypto.secure_compare(expected)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp verify_password(password, "legacy_sha256$" <> expected) do
    :crypto.hash(:sha256, password)
    |> Base.encode16(case: :lower)
    |> Plug.Crypto.secure_compare(expected)
  end

  defp verify_password(_, _), do: false

  defp upgrade_legacy_hash(%{"password_hash" => "legacy_sha256$" <> _} = user, password) do
    upgraded =
      user
      |> Map.put("password_hash", password_hash(password))
      |> Map.put("updated_at", DateTime.utc_now())

    :ok = :khepri.put(["users", user["id"]], upgraded)
    upgraded
  end

  defp upgrade_legacy_hash(user, _password), do: user

  defp public_user(user), do: Map.drop(user, ["password_hash"])
end
