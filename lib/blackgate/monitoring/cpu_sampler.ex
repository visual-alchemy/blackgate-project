defmodule Blackgate.Monitoring.CpuSampler do
  @moduledoc """
  Samples `:cpu_sup.util/0` from a persistent process on a short fixed interval.

  `:cpu_sup.util/0` returns CPU utilization since the *last call by the same
  process*. When it is called from a short-lived process (e.g. the process
  spawned per HTTP request by `:rpc.call/4`), every call looks like a first-time
  caller with no previous sample, so cpu_sup falls back to returning the
  cumulative average since boot instead of the current rate — the metric freezes.

  This GenServer keeps a stable PID and calls `:cpu_sup.util/0` on a timer, so
  each sample measures the delta over a short, meaningful window.
  """

  use GenServer

  @sample_interval 2_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get() :: float() | nil
  def get do
    case Process.whereis(__MODULE__) do
      nil -> sample()
      pid -> GenServer.call(pid, :get)
    end
  end

  @impl true
  def init(_opts) do
    # Establish a baseline so the first scheduled sample measures a real delta
    # rather than the cumulative average since boot.
    _ = sample()
    schedule_sample()
    {:ok, %{cpu: nil}}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state.cpu, state}
  end

  @impl true
  def handle_info(:sample, state) do
    schedule_sample()
    {:noreply, %{state | cpu: sample()}}
  end

  defp sample do
    util =
      try do
        :cpu_sup.util()
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    if is_number(util), do: util, else: nil
  end

  defp schedule_sample do
    Process.send_after(self(), :sample, @sample_interval)
  end
end
