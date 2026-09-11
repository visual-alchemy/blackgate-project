defmodule BlackgateWeb.Router do
  use BlackgateWeb, :router

  alias Blackgate.Accounts

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_no_parse do
    plug :accepts, ["*/*"]
    plug :check_auth
  end

  pipeline :auth do
    plug :check_auth
  end

  pipeline :admin do
    plug :require_admin
  end

  scope "/health", BlackgateWeb do
    get "/", HealthController, :index
  end

  scope "/api", BlackgateWeb do
    pipe_through :api

    post "/login", AuthController, :login
  end

  scope "/api", BlackgateWeb do
    pipe_through [:api, :auth]

    put "/auth/credentials", AuthController, :update_credentials
  end

  scope "/api", BlackgateWeb do
    pipe_through [:api, :auth, :admin]

    resources "/users", UserController, only: [:index, :create, :update, :delete]
    get "/system/updates", UpdateController, :index
    post "/system/updates", UpdateController, :upload
    post "/system/updates/:version/deploy", UpdateController, :deploy
  end

  scope "/api", BlackgateWeb do
    pipe_through [:api, :auth]

    resources "/routes", RouteController, except: [:new, :edit]
    get "/routes/:route_id/start", RouteController, :start
    get "/routes/:route_id/stop", RouteController, :stop
    get "/routes/:route_id/restart", RouteController, :restart
    post "/routes/:route_id/switch-source", RouteController, :switch_source
    get "/routes/:route_id/stats", RouteController, :stats
    get "/routes/:route_id/destination-stats", RouteController, :destination_stats
    get "/routes/:route_id/preview", RouteController, :preview
    post "/routes/bulk-action", RouteController, :bulk_action
    post "/routes/:route_id/clone", RouteController, :clone
    get "/routes/:route_id/destinations", DestinationController, :index
    post "/routes/:route_id/destinations", DestinationController, :create
    get "/routes/:route_id/destinations/:dest_id", DestinationController, :show
    put "/routes/:route_id/destinations/:dest_id", DestinationController, :update
    delete "/routes/:route_id/destinations/:dest_id", DestinationController, :delete

    get "/backup/export", BackupController, :export
    get "/backup/create-download-link", BackupController, :create_download_link
    get "/backup/create-backup-download-link", BackupController, :create_backup_download_link
    post "/backup/import-routes", BackupController, :import_routes

    get "/system/pipelines", SystemController, :list_pipelines
    get "/system/pipelines/detailed", SystemController, :list_pipelines_detailed
    post "/system/pipelines/:pid/kill", SystemController, :kill_pipeline
    get "/system/status", SystemController, :status
    get "/system/report", SystemController, :report
    post "/system/actions/:action", SystemController, :perform_action

    get "/nodes", NodeController, :index
    get "/nodes/:id", NodeController, :show

    get "/network/interfaces", NetworkController, :index

    # Events
    get "/events", EventController, :index
    get "/events/counts", EventController, :counts
    delete "/events", EventController, :clear

    # License management
    get "/license", LicenseController, :show
    post "/license/activate", LicenseController, :activate
    delete "/license/deactivate", LicenseController, :deactivate
  end

  # TODO: improve this
  scope "/api", BlackgateWeb do
    pipe_through [:api_no_parse]
    post "/restore", BackupController, :restore
  end

  scope "/backup", BlackgateWeb do
    get "/:session_id/download", BackupController, :download
    get "/:session_id/download_backup", BackupController, :download_backup
  end

  scope "/", BlackgateWeb do
    pipe_through(:browser)

    get "/", PageController, :index
    get "/*path", PageController, :index
  end

  defp check_auth(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Cachex.get(Blackgate.Cache, "auth_session:#{token}") do
          {:ok, nil} ->
            conn
            |> put_status(403)
            |> Phoenix.Controller.json(%{error: "Unauthorized"})
            |> halt()

          {:ok, %{"id" => id}} ->
            case Accounts.session_user(id) do
              {:ok, user} -> Plug.Conn.assign(conn, :current_user, user)
              _ -> unauthorized(conn)
            end

          _ ->
            unauthorized(conn)
        end

      _ ->
        conn
        |> put_status(403)
        |> Phoenix.Controller.json(%{error: "Authorization header missing"})
        |> halt()
    end
  end

  defp require_admin(conn, _opts) do
    if get_in(conn.assigns, [:current_user, "role"]) == "admin" do
      conn
    else
      conn
      |> put_status(403)
      |> Phoenix.Controller.json(%{error: "Admin role required"})
      |> halt()
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(403)
    |> Phoenix.Controller.json(%{error: "Unauthorized"})
    |> halt()
  end
end
