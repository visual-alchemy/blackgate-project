defmodule BlackgateWeb.HealthController do
  use BlackgateWeb, :controller

  def index(conn, _params) do
    conn
    |> send_resp(200, "")
  end
end
