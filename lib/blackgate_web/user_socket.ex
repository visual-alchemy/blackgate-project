defmodule BlackgateWeb.UserSocket do
  use Phoenix.Socket

  channel "route:*", BlackgateWeb.StatsChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Cachex.get(Blackgate.Cache, "auth_session:#{token}") do
      {:ok, value} when not is_nil(value) ->
        {:ok, assign(socket, :token, token)}

      _ ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end
