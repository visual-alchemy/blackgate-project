defmodule Blackgate.Monitoring.OsMon do
  @moduledoc false

  @doc """
  System RAM usage as a percentage.

  Uses `available_memory` (kernel `MemAvailable`) rather than `free_memory`:
  MemFree excludes reclaimable page cache and buffers, so a healthy box with a
  warm cache reported ~90% used while `free`/`top` showed ~32%. Falls back to
  `free_memory` where the kernel does not report MemAvailable (e.g. macOS).
  """
  @spec ram_usage() :: float()
  def ram_usage do
    mem = :memsup.get_system_memory_data()
    total = Keyword.get(mem, :total_memory) || 0
    available = Keyword.get(mem, :available_memory) || Keyword.get(mem, :free_memory) || 0

    if total > 0 do
      max(0.0, 100 - available / total * 100)
    else
      0.0
    end
  end

  @spec cpu_la() :: %{avg1: float(), avg5: float(), avg15: float()}
  def cpu_la do
    %{
      avg1: :cpu_sup.avg1() / 256,
      avg5: :cpu_sup.avg5() / 256,
      avg15: :cpu_sup.avg15() / 256
    }
  end

  @doc """
  Current CPU utilisation percentage.

  Delegates to `Blackgate.Monitoring.CpuSampler`. Calling `:cpu_sup.util/0`
  directly from a short-lived request process makes cpu_sup treat every call as
  that caller's first sample and return the cumulative average since boot, so
  the Dashboard value froze (7.3% while the box was pinned at 100%).
  """
  @spec cpu_util() :: float() | nil
  def cpu_util do
    Blackgate.Monitoring.CpuSampler.get()
  end

  @spec swap_usage() :: float() | nil
  def swap_usage do
    mem = :memsup.get_system_memory_data()

    with total_swap when is_integer(total_swap) <- Keyword.get(mem, :total_swap),
         free_swap when is_integer(free_swap) <- Keyword.get(mem, :free_swap) do
      100 - free_swap / total_swap * 100
    else
      _ -> nil
    end
  end

  @doc """
  Get all system stats in a single call
  """
  @spec get_all_stats() :: %{
          cpu: float() | {:error, term()},
          ram: float(),
          swap: float() | nil,
          cpu_la: %{avg1: float(), avg5: float(), avg15: float()}
        }
  def get_all_stats do
    %{
      cpu: cpu_util(),
      ram: ram_usage(),
      swap: swap_usage(),
      cpu_la: cpu_la()
    }
  end
end
