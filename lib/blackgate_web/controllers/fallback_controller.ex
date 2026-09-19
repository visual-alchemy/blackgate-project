defmodule BlackgateWeb.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  See `Phoenix.Controller.action_fallback/1` for more details.
  """
  use BlackgateWeb, :controller

  def call(conn, {:error, "SDI output not supported on Blackgate Lite" = message}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: message})
  end

  # This clause is an example of how to handle resources that cannot be found.
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(html: BlackgateWeb.ErrorHTML, json: BlackgateWeb.ErrorJSON)
    |> render(:"404")
  end
end
