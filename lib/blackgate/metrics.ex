defmodule Blackgate.Metrics do
  @moduledoc """
  Helper functions for working with metrics.
  """

  require Logger

  alias Blackgate.Metrics.Connection

  def event(k, v, tags \\ %{}, ts \\ System.system_time()) do
    # Logger.debug("Event: #{k} #{inspect(v)}")

    if Application.get_env(:blackgate, :export_metrics?, false) do
      Connection.write(%{
        measurement: "blackgate_routes_stats",
        fields: %{k => v},
        tags: tags,
        timestamp: ts
      })
    else
      :ok
    end
  end
end
