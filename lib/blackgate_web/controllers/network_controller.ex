defmodule BlackgateWeb.NetworkController do
  use BlackgateWeb, :controller

  alias Blackgate.Db

  @alias_max_length 32

  @doc """
  Returns list of network interfaces with their IP addresses.
  Uses Erlang's :inet.getifaddrs/0 to detect all interfaces.
  """
  def index(conn, _params) do
    aliases =
      case Db.get_network_interface_aliases() do
        {:ok, value} -> value
        {:error, _reason} -> %{}
      end

    interfaces = get_network_interfaces(aliases)
    json(conn, %{interfaces: interfaces})
  end

  def update_alias(conn, %{"mac" => mac, "alias" => alias}) do
    with {:ok, mac} <- normalize_mac(mac),
         {:ok, alias} <- normalize_alias(alias),
         :ok <- ensure_alias_unique(mac, alias),
         {:ok, _aliases} <- Db.set_network_interface_alias(mac, alias) do
      json(conn, %{mac: mac, alias: alias})
    else
      {:error, message} when is_binary(message) ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Could not save interface alias"})
    end
  end

  def update_alias(conn, _params),
    do: conn |> put_status(:bad_request) |> json(%{error: "MAC address and alias are required"})

  defp get_network_interfaces(aliases) do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.map(&parse_interface/1)
        |> Enum.map(&Map.put(&1, :alias, Map.get(aliases, &1.mac)))
        |> Enum.filter(&has_ipv4?/1)
        |> Enum.sort_by(& &1.name)

      {:error, _reason} ->
        []
    end
  end

  defp parse_interface({name, opts}) do
    %{
      name: to_string(name),
      address: get_ipv4_address(opts),
      netmask: get_netmask(opts),
      mac: get_mac_address(opts),
      up: :up in Keyword.get(opts, :flags, []),
      broadcast: get_broadcast(opts)
    }
  end

  defp get_ipv4_address(opts) do
    opts
    |> Keyword.get_values(:addr)
    |> Enum.find(&is_ipv4?/1)
    |> format_ip()
  end

  defp get_netmask(opts) do
    opts
    |> Keyword.get_values(:netmask)
    |> Enum.find(&is_ipv4?/1)
    |> format_ip()
  end

  defp get_broadcast(opts) do
    opts
    |> Keyword.get_values(:broadaddr)
    |> Enum.find(&is_ipv4?/1)
    |> format_ip()
  end

  defp get_mac_address(opts) do
    case Keyword.get(opts, :hwaddr) do
      nil ->
        nil

      hwaddr when is_list(hwaddr) ->
        hwaddr
        |> Enum.map(&:io_lib.format("~2.16.0B", [&1]))
        |> Enum.join(":")
        |> String.downcase()

      _ ->
        nil
    end
  end

  defp is_ipv4?({a, b, c, d})
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255
  end

  defp is_ipv4?(_), do: false

  defp format_ip(nil), do: nil
  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp has_ipv4?(%{address: nil}), do: false
  defp has_ipv4?(_), do: true

  defp normalize_mac(mac) when is_binary(mac) do
    normalized = String.downcase(String.trim(mac))

    if Regex.match?(~r/^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$/, normalized),
      do: {:ok, normalized},
      else: {:error, "Invalid interface MAC address"}
  end

  defp normalize_mac(_), do: {:error, "Invalid interface MAC address"}

  # Blank alias means remove the custom label and use the Linux interface name.
  defp normalize_alias(alias) when is_binary(alias) do
    alias = String.trim(alias)

    cond do
      alias == "" ->
        {:ok, nil}

      String.length(alias) > @alias_max_length ->
        {:error, "Alias must be 32 characters or fewer"}

      not Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9 ._-]*$/, alias) ->
        {:error, "Alias may use letters, numbers, spaces, dots, dashes, and underscores"}

      true ->
        {:ok, alias}
    end
  end

  defp normalize_alias(_), do: {:error, "Alias must be text"}

  defp ensure_alias_unique(_mac, nil), do: :ok

  defp ensure_alias_unique(mac, alias) do
    case Db.get_network_interface_aliases() do
      {:ok, aliases} ->
        duplicate? =
          Enum.any?(aliases, fn {other_mac, other_alias} ->
            other_mac != mac and String.downcase(other_alias) == String.downcase(alias)
          end)

        if duplicate?, do: {:error, "Alias is already used by another interface"}, else: :ok

      {:error, _reason} ->
        {:error, "Could not validate interface aliases"}
    end
  end
end
