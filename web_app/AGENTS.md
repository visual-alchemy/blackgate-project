# Frontend Application Context (`web_app/`)

Welcome! This folder contains the React frontend application for managing the Blackgate SRT Gateway.

## 🛠️ Technology Stack & Environment

- **Core Framework:** React 18
- **Build Tool:** Vite
- **UI Component Library:** Ant Design 5
- **Styling:** Vanilla CSS (located in `src/index.css`)
- **WebSocket connection:** Phoenix Channels

## 🏗️ Folder Layout

- `src/pages/`: Route manager dashboards, source/destination edit views, settings, and node metrics lists.
- `src/hooks/useRouteStats.js`: Hybrid WebSocket-polling React hook for real-time telemetry.
- `src/utils/socket.js`: WebSocket wrapper client.

## 🚀 Setup & Execution Commands

Run from `web_app/` folder:
- **Install dependencies:** `npm install` (or run `make install` from project root).
- **Start development server:** `npm run dev` (runs on `http://localhost:5173`; or run `make dev-all` from project root).
- **Build assets:** `npm run build` (or run `make build` from project root; builds assets to `priv/static`).
