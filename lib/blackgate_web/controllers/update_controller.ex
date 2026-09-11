defmodule BlackgateWeb.UpdateController do
  use BlackgateWeb, :controller

  alias Blackgate.SystemControl

  def index(conn, _params) do
    case SystemControl.updates() do
      {:ok, updates} -> json(conn, %{data: updates})
      _ -> conn |> put_status(500) |> json(%{error: "Could not list updates"})
    end
  end

  def upload(conn, %{"filename" => filename}) do
    with {:ok, version} <- version_from_filename(filename),
         {:ok, body, _conn} <-
           Plug.Conn.read_body(conn, length: 50_000_000, read_length: 1_000_000),
         :ok <- File.mkdir_p("/opt/blackgate/incoming"),
         :ok <- File.write("/opt/blackgate/incoming/#{version}.bgupdate", body) do
      conn |> put_status(:created) |> json(%{version: version})
    else
      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: "Upload failed: #{inspect(reason)}"})

      _ ->
        conn |> put_status(422) |> json(%{error: "Invalid update package"})
    end
  end

  def deploy(conn, %{"version" => version}) do
    with {:ok, version} <- version_from_filename(version <> ".bgupdate"),
         {:ok, message} <- SystemControl.deploy(version) do
      conn |> put_status(:accepted) |> json(%{message: message, version: version})
    else
      {:error, reason} -> conn |> put_status(422) |> json(%{error: "Deploy failed: #{reason}"})
    end
  end

  defp version_from_filename(filename) do
    case Regex.run(~r/^([A-Za-z0-9][A-Za-z0-9._-]{0,63})\.bgupdate$/, filename) do
      [_, version] -> {:ok, String.replace_prefix(version, "blackgate-", "")}
      _ -> {:error, :invalid_filename}
    end
  end
end
