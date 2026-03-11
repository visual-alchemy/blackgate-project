# Blackgate Web App

The `web_app/` directory contains the React frontend for Blackgate's management dashboard. It provides a real-time interface for managing SRT/UDP routes, monitoring stream statistics, and configuring system settings.

## Tech Stack

| Technology | Purpose |
|------------|---------|
| **React 18** | UI framework |
| **Vite** | Build tool & dev server |
| **Ant Design** | Component library |
| **React Router** | Client-side routing |

## Getting Started

```bash
# Install dependencies
yarn install

# Start development server (hot-reload)
yarn dev
```

🌐 **Dev URL:** http://localhost:5173  
📡 **API Proxy:** Vite proxies `/api` requests to `http://localhost:4000`

## Build for Production

```bash
yarn build
```

Output goes to `dist/`, which is copied into the Phoenix `priv/static/` directory during `make build`.

## Project Structure

```
web_app/
├── src/
│   ├── main.jsx            # App entry point
│   ├── App.jsx             # Router & layout setup
│   ├── components/         # Shared components (MainLayout, RouteStats, etc.)
│   ├── pages/              # Page components
│   │   ├── Dashboard.jsx   # System overview
│   │   ├── Login.jsx       # Authentication
│   │   ├── License.jsx     # License management
│   │   ├── Settings.jsx    # Backup/restore, credentials
│   │   ├── routes/         # Route CRUD & detail pages
│   │   └── system/         # Pipeline & node management
│   └── utils/              # API client, auth helpers, constants
├── public/                 # Static assets (favicon, etc.)
├── vite.config.js          # Vite configuration
└── package.json
```

## Key Pages

| Page | Path | Description |
|------|------|-------------|
| Dashboard | `/` | System metrics (CPU, RAM, routes) |
| Routes | `/routes` | Route list with search, filter, bulk actions |
| Route Detail | `/routes/:id` | Source config, destinations, live stats |
| Settings | `/settings` | Backup/restore, credential management |
| License | `/license` | License activation & status |
