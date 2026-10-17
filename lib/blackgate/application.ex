defmodule Blackgate.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    :ok =
      :gen_event.swap_sup_handler(
        :erl_signal_server,
        {:erl_signal_handler, []},
        {Blackgate.SignalHandler, []}
      )

    khepri_data_dir = System.get_env("DATABASE_DATA_DIR", "#{File.cwd!()}/khepri##{node()}")
    Logger.notice("Database directory: #{khepri_data_dir}")
    Logger.notice("Starting database: #{inspect(:khepri.start(khepri_data_dir))}")

    :syn.add_node_to_scopes([:routes])
    runtime_schedulers = System.schedulers_online()
    Logger.info("Runtime schedulers: #{runtime_schedulers}")

    stats_socket = Blackgate.stats_socket_path()
    assert_stats_socket_free!(stats_socket)

    {:ok, ranch_listener} =
      :ranch.start_listener(
        :hydra_unix_sock,
        :ranch_tcp,
        %{
          max_connections: String.to_integer(System.get_env("MAX_CONNECTIONS") || "75000"),
          num_acceptors: String.to_integer(System.get_env("NUM_ACCEPTORS") || "100"),
          socket_opts: [
            ip: {:local, stats_socket},
            port: 0,
            keepalive: true
          ]
        },
        Blackgate.UnixSockHandler,
        %{}
      )

    Logger.info("Ranch listener: #{inspect(ranch_listener)}")

    children = [
      Blackgate.RouteStatsRegistry,
      Blackgate.EventLog,
      # Blackgate.ErlSysMon,  # disabled: OTP 29 os_mon incompatibility
      Blackgate.Monitoring.CpuSampler,
      Blackgate.License,
      {PartitionSupervisor,
       child_spec: DynamicSupervisor, strategy: :one_for_one, name: Blackgate.DynamicSupervisor},
      {Registry,
       keys: :unique, name: Blackgate.Registry.MsgHandlers, partitions: runtime_schedulers},
      BlackgateWeb.Telemetry,
      {Phoenix.PubSub, name: Blackgate.PubSub, partitions: runtime_schedulers},
      BlackgateWeb.Endpoint,
      Blackgate.Metrics.Connection
    ]

    children = [{Cachex, name: Blackgate.Cache} | children]

    opts = [strategy: :one_for_one, name: Blackgate.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    BlackgateWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @impl true
  def stop(_state) do
    Logger.info("Stopping application")
  end

  @doc """
  Refuses to start when another node is already listening on the stats socket.

  Binding a path that already has a live listener unlinks that listener's socket
  (the file then points at a dead socket), and every engine the running node
  starts afterwards dies with `connect: Connection refused (os error 111)` while
  routes whose engines are already connected keep working — a silent, very
  confusing failure. A leftover file with no listener is fine: Ranch unlinks it
  when binding.
  """
  @spec assert_stats_socket_free!(String.t()) :: :ok
  def assert_stats_socket_free!(path) do
    case :gen_tcp.connect({:local, path}, 0, [:binary], 200) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

        raise """
        #{path} already has a live listener: another Blackgate node is running on
        this host. Stop it first (`make stop`) — binding the same path would unbind
        the running node's socket, and every engine it starts afterwards would fail
        to connect with ECONNREFUSED.
        """

      {:error, _} ->
        :ok
    end
  end
end
