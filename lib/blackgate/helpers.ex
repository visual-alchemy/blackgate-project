defmodule Blackgate.Helpers do
  @moduledoc false

  @doc """
  Sets the maximum heap size for the current process. The `max_heap_size` parameter is in megabytes.

  ## Parameters

  - `max_heap_size`: The maximum heap size in megabytes.
  """
  @spec set_max_heap_size(pos_integer()) :: map()
  def set_max_heap_size(max_heap_size) do
    max_heap_words = div(max_heap_size * 1024 * 1024, :erlang.system_info(:wordsize))
    Process.flag(:max_heap_size, %{size: max_heap_words})
  end

  def sys_kill(process_id) do
    # A child that already exited makes `kill` print "No such process" on stderr, which then lands
    # in the release log as a scary line during every normal reconnect. Keep the exit status, drop
    # the noise.
    System.cmd("kill", ["-9", "#{process_id}"], stderr_to_stdout: true)
  end
end
