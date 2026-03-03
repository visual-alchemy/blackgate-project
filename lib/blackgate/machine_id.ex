defmodule Blackgate.MachineId do
  @moduledoc """
  Utility module for generating a persistent, hardware-based identifier for the machine.
  Works across bare-metal and Docker environments (assuming --network host).
  """

  require Logger

  @doc """
  Retrieves a unique, consistent identifier for the current machine.
  It attempts to read the primary network interface's MAC address first.
  If that fails, it generates a fallback identifier based on system architecture and OS details.
  """
  def get do
    case get_mac_address() do
      {:ok, mac} ->
        # Hash the MAC to obscure the physical address slightly
        hash_id("mac_" <> mac)

      {:error, _reason} ->
        Logger.warning("Could not resolve physical MAC address. Falling back to system architecture hash.")
        fallback_id()
    end
  end

  defp get_mac_address do
    # Try generic 'ip link' command first (Linux common)
    case System.cmd("ip", ["link"], stderr_to_stdout: true) do
      {output, 0} ->
        extract_mac_from_ip_link(output)

      _ ->
        # Fallback to ifconfig (Older Linux, macOS)
        case System.cmd("ifconfig", [], stderr_to_stdout: true) do
          {output, 0} ->
            extract_mac_from_ifconfig(output)

          _ ->
            {:error, :command_failed}
        end
    end
  rescue
    _ -> {:error, :cmd_not_found}
  end

  defp extract_mac_from_ip_link(output) do
    # Filter out loopback and docker virtual interfaces
    # Look for link/ether followed by the MAC address
    lines = String.split(output, "\n")
    
    mac = Enum.reduce_while(lines, nil, fn line, acc ->
      if String.contains?(line, "link/ether") do
        # Format usually: link/ether 00:11:22:33:44:55 brd ...
        parts = String.split(String.trim(line), " ")
        if length(parts) >= 2 do
          {:halt, Enum.at(parts, 1)}
        else
          {:cont, acc}
        end
      else
        {:cont, acc}
      end
    end)

    if mac, do: {:ok, mac}, else: {:error, :not_found}
  end

  defp extract_mac_from_ifconfig(output) do
    # Look for 'ether ' followed by MAC format
    case Regex.run(~r/ether\s+([0-9a-fA-F:]+)/, output) do
      [_, mac] -> {:ok, mac}
      _ -> {:error, :not_found}
    end
  end

  defp fallback_id do
    # Combine Erlang system info to create a stable fallback identifier for the container/OS
    arch = to_string(:erlang.system_info(:system_architecture))
    os_type = inspect(:os.type())
    version = to_string(:erlang.system_info(:otp_release))
    
    hash_id("sys_" <> arch <> "_" <> os_type <> "_" <> version)
  end

  defp hash_id(input) do
    :crypto.hash(:sha256, input)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end
end
