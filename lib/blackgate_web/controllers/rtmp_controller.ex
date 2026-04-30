defmodule BlackgateWeb.RtmpController do
  @moduledoc """
  Handles MediaMTX auth webhook for RTMP stream key validation.

  MediaMTX calls POST /api/rtmp/auth for every publish/read/playback action.
  - publish: validate the stream_key exists in a started RTMP route
  - read/playback: always allowed (HLS is public for monitoring)
  """

  use BlackgateWeb, :controller
  require Logger

  alias Blackgate.Db

  @doc """
  MediaMTX auth webhook handler.

  Expected payload:
    { "action": "publish" | "read" | "playback",
      "path": "live/STREAM_KEY",
      "ip": "1.2.3.4",
      "user": "", "password": "",
      "id": "..." }

  Returns 200 OK to allow, 401 to deny.
  """
  def auth(conn, %{"action" => "publish", "path" => path} = params) do
    stream_key = extract_stream_key(path)
    Logger.info("RTMP auth webhook: publish path=#{path} key=#{stream_key} ip=#{params["ip"]}")

    case find_rtmp_route_by_key(stream_key) do
      {:ok, route} ->
        Logger.info("RTMP auth: accepted stream_key=#{stream_key} route=#{route["id"]}")
        conn |> put_status(:ok) |> text("OK")

      :not_found ->
        Logger.warning("RTMP auth: rejected unknown stream_key=#{stream_key}")
        conn |> put_status(:unauthorized) |> text("Unauthorized")
    end
  end

  # All reads/playback are public — HLS is for monitoring
  def auth(conn, %{"action" => action} = params) do
    Logger.debug("RTMP auth webhook: #{action} path=#{params["path"]} — allowed (public)")
    conn |> put_status(:ok) |> text("OK")
  end

  # Fallback for missing action
  def auth(conn, _params) do
    conn |> put_status(:ok) |> text("OK")
  end

  # ---- Private ----

  defp extract_stream_key(path) do
    # path is like "live/my-stream-key" — take the last segment
    path
    |> String.split("/")
    |> List.last()
    |> String.trim()
  end

  defp find_rtmp_route_by_key(stream_key) when is_binary(stream_key) and stream_key != "" do
    case Db.list_routes() do
      {:ok, routes} ->
        match =
          Enum.find(routes, fn route ->
            route["schema"] == "RTMP" &&
              get_in(route, ["schema_options", "stream_key"]) == stream_key
          end)

        if match, do: {:ok, match}, else: :not_found

      _ ->
        :not_found
    end
  end

  defp find_rtmp_route_by_key(_), do: :not_found
end
