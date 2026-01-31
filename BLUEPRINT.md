# PROJECT BLUEPRINT - Blackgate

## Project Overview
Blackgate is an open-source SRT Video Gateway for high-performance video routing with secure, reliable transport. It provides real-time stream routing from SRT/UDP sources to multiple destinations with live statistics, passphrase authentication, and a modern web dashboard for management.

## Tech Stack
- **Frontend**: React 19 + Vite 6 + Ant Design 5
- **Backend**: Elixir 1.17+ / Phoenix 1.7 / Cowboy
- **Database**: Khepri (Raft consensus DB) + ETS (real-time stats)
- **Key Libraries**:
  - `phoenix` - Web framework with REST API
  - `khepri` - Distributed database with Raft consensus
  - `cachex` - In-memory caching for auth sessions
  - `syn` - Process registry
  - `telemetry_metrics` - Metrics collection
  - `instream` - InfluxDB/VictoriaMetrics client
  - `antd` - UI component library
  - `react-router-dom` - Frontend routing
- **Streaming**: GStreamer (C) with SRT/UDP support
- **Deployment**: Docker Compose + Makefile (baremetal)

## Architecture Overview
```
┌─────────────────────────────────────────────────────────────────┐
│                        Blackgate Server                          │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐       │
│  │   React UI   │◄──►│  Phoenix API │◄──►│   Khepri DB  │       │
│  │  (Vite/Antd) │    │  (REST/WS)   │    │  (Routes)    │       │
│  └──────────────┘    └──────┬───────┘    └──────────────┘       │
│                             │                                    │
│                      Unix Socket IPC                             │
│                             │                                    │
│                      ┌──────▼───────┐                           │
│                      │  GStreamer   │                           │
│                      │  Pipeline (C)│                           │
│                      └──────┬───────┘                           │
└─────────────────────────────┼───────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
         SRT Source                      UDP Source
              │                               │
              └───────────────┬───────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
         SRT Dest                        UDP Dest
```

## File Structure
```
.
├── config/                    # Elixir configuration
│   ├── config.exs            # Base config
│   ├── dev.exs               # Development config
│   ├── prod.exs              # Production config
│   ├── runtime.exs           # Runtime env variables
│   └── nginx-rtmp.conf       # RTMP server config
├── lib/
│   ├── blackgate/            # Core business logic
│   │   ├── api/              # API helpers
│   │   ├── application.ex    # OTP application
│   │   ├── db.ex             # Khepri database operations
│   │   ├── route_handler.ex  # GStreamer pipeline builder
│   │   ├── unix_sock_handler.ex  # IPC with C pipeline
│   │   ├── route_stats_registry.ex  # Live stats storage
│   │   └── process_monitor.ex    # Pipeline lifecycle
│   └── blackgate_web/        # Phoenix web layer
│       ├── controllers/      # REST API controllers
│       ├── router.ex         # API routes
│       └── endpoint.ex       # HTTP endpoint config
├── native/                   # C application (GStreamer)
│   ├── src/                  # C source files
│   │   ├── gst_pipeline.c   # Pipeline implementation
│   │   └── unix_socket.c    # IPC handler
│   ├── include/              # Header files
│   └── Makefile              # C build system
├── web_app/                  # React frontend
│   ├── src/
│   │   ├── components/       # Reusable UI components
│   │   ├── pages/            # Route pages (Dashboard, Routes)
│   │   ├── utils/            # API client, helpers
│   │   └── main.jsx          # App entry point
│   └── package.json          # Frontend dependencies
├── priv/                     # Static assets, migrations
├── test/                     # ExUnit tests
├── docker-compose.yml        # Container orchestration
├── Dockerfile                # Production image
├── Makefile                  # Build/deploy commands
└── mix.exs                   # Elixir project config
```

## Key Decisions & Conventions
- **Authentication**: Bearer token with Cachex session storage (no JWT, simple token-based)
- **Error Handling**: Phoenix controller pattern with JSON error responses, `{:ok, value}` / `{:error, reason}` tuples
- **Naming**:
  - Elixir: `snake_case` for functions/variables, `PascalCase` for modules
  - JavaScript: `camelCase` for functions/variables, `PascalCase` for components
  - Files: `snake_case.ex` (Elixir), `PascalCase.jsx` (React components)
- **Styling**: Ant Design component library with custom CSS
- **Environment Variables**:
  - `API_AUTH_USERNAME` - API login username (required)
  - `API_AUTH_PASSWORD` - API login password (required)
  - `PORT` - HTTP server port (default: 4000)
  - `PHX_HOST` - Phoenix host binding
  - `DATABASE_DATA_DIR` - Khepri storage path
  - `VICTORIAMETRICS_HOST/PORT` - Metrics export (optional)

## Module Relationships
**Route Lifecycle**: `RouteController` → `Blackgate.DB` (persist) → `RouteHandler.build_pipeline/1` → spawns C binary via `ProcessMonitor` → `UnixSockHandler` receives stats via Unix socket → `RouteStatsRegistry` stores in ETS → API returns live stats.

**Auth Flow**: `AuthController.login/2` validates credentials against env vars → generates UUID token → stores in `Cachex` with TTL → subsequent requests use `check_auth/2` plug to validate Bearer token.

**IPC Communication**: Elixir spawns GStreamer C binary with Unix socket path → C process sends JSON stats periodically → `UnixSockHandler` (GenServer) parses and updates `RouteStatsRegistry`.

## LLM Development Rules
- No new dependencies without explicit approval
- Follow existing code patterns and naming conventions
- Write tests before major changes
- Maintain current architecture layers (Controller → DB → Handler → C Pipeline)
- Keep responses under 4000 tokens
- Use `Blackgate.DB` for all Khepri operations, never access Khepri directly
- All API endpoints require `pipe_through [:api, :auth]` except `/login` and `/health`
- GStreamer pipeline changes require updates to both `route_handler.ex` and `gst_pipeline.c`
