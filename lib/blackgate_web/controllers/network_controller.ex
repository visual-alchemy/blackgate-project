defmodule BlackgateWeb.NetworkController do
  use BlackgateWeb, :controller

  @doc """
  Returns list of network interfaces with their IP addresses.
  Uses Erlang's :inet.getifaddrs/0 to detect all interfaces.
  """
  def index(conn, _params) do
    interfaces = get_network_interfaces()
    json(conn, %{interfaces: interfaces})
  end

  defp get_network_interfaces do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.map(&parse_interface/1)
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
      nil -> nil
      hwaddr when is_list(hwaddr) ->
        hwaddr
        |> Enum.map(&:io_lib.format("~2.16.0B", [&1]))
        |> Enum.join(":")
        |> String.downcase()
      _ -> nil
    end
  end

  defp is_ipv4?({a, b, c, d}) when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255
  end
  defp is_ipv4?(_), do: false

  defp format_ip(nil), do: nil
  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp has_ipv4?(%{address: nil}), do: false
  defp has_ipv4?(_), do: true
end
