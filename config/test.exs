import Config

System.put_env(
  "DATABASE_DATA_DIR",
  Path.join(System.tmp_dir!(), "blackgate-khepri-test-#{System.pid()}")
)

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :blackgate, BlackgateWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "o4JBd+wOK5JJIHHOZ/WMk00xrG9dN0//FF1MIBkDPzM+nRTN+5+L9hvMVX+805L0",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Never share the stats socket with a running release on this host: binding the
# production path from a test run unlinks the live listener's socket and leaves a
# dead file behind, after which every engine fails with ECONNREFUSED.
config :blackgate,
  stats_socket_path: Path.join(System.tmp_dir!(), "blackgate_stats_#{System.pid()}.sock")

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
