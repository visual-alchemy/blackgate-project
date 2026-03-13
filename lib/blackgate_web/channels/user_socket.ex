defmodule BlackgateWeb.UserSocket do
  use Phoenix.Socket

  ## Channels
  channel "stats:*", BlackgateWeb.StatsChannel

  @impl true
  def connect(params, socket, _connect_info) do
    # Try token auth first; if no token or invalid, still allow connection
    # because stats channels are read-only and do not expose sensitive data.
    case params do
      %{"token" => token} when is_binary(token) and token != "" ->
        case Cachex.get(Blackgate.Cache, "auth_session:#{token}") do
          {:ok, nil} -> {:ok, socket}  # allow anyway for stats
          {:ok, _}   -> {:ok, socket}
          _          -> {:ok, socket}
        end

      _ ->
        {:ok, socket}
    end
  end

  @impl true
  def id(_socket), do: nil
end
