defmodule BlackgateWeb.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  See `Phoenix.Controller.action_fallback/1` for more details.
  """
  use BlackgateWeb, :controller

  # This clause is an example of how to handle resources that cannot be found.
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(html: BlackgateWeb.ErrorHTML, json: BlackgateWeb.ErrorJSON)
    |> render(:"404")
  end

  # `Db.update_route/2` and `Db.update_destination/3` answer these when the record is gone - a second
  # dashboard tab, a restore, a delete in between. The tuple did not match the clause above, so the
  # fallback raised `FunctionClauseError` and the dashboard saw a 500 for a record that simply is not
  # there any more. A refusal shaped like bad input belongs to the operator, not to the server: answer a
  # status and say what happened. The frontend reads `message` first (`web_app/src/utils/api.js`).
  def call(conn, {:error, :route_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{message: "Route not found"})
  end

  def call(conn, {:error, :destination_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{message: "Destination not found"})
  end

  # `Db.create_destinations/2` halts with this when a create-route request carries an entry that is not
  # an object. That is the operator's input, so 400 with the entry that was refused.
  def call(conn, {:error, {:invalid_destination, destination}}) do
    conn
    |> put_status(:bad_request)
    |> json(%{message: "A destination must be an object, got: #{inspect(destination)}"})
  end
end
