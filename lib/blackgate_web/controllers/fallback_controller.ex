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

  # A refused destination schema is the operator's input, not a server fault: answer 400 with the
  # reason the boundary rejected it instead of letting the unmatched tuple surface as a 500.
  def call(conn, {:error, {:unsupported_destination, schema}}) do
    label = if is_binary(schema), do: schema, else: "missing"

    conn
    |> put_status(:bad_request)
    |> json(%{
      message:
        "Destination schema #{label} is not supported: this build delivers over the network only (SRT or UDP)."
    })
  end
end
