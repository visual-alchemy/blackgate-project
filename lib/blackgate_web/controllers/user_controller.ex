defmodule BlackgateWeb.UserController do
  use BlackgateWeb, :controller

  alias Blackgate.Accounts

  def index(conn, _params) do
    case Accounts.list_users() do
      {:ok, users} -> json(conn, %{data: users})
      _ -> conn |> put_status(500) |> json(%{error: "Could not list users"})
    end
  end

  def create(conn, params) do
    case Accounts.create_user(params) do
      {:ok, user} ->
        conn |> put_status(:created) |> json(%{data: user})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Could not create user: #{reason}"})
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Accounts.update_user(id, Map.drop(params, ["id"])) do
      {:ok, user} ->
        json(conn, %{data: user})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Could not update user: #{reason}"})
    end
  end

  def delete(conn, %{"id" => id}) do
    case Accounts.delete_user(id) do
      :ok ->
        json(conn, %{deleted: true})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Could not delete user: #{reason}"})
    end
  end
end
