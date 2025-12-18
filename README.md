<p align="center">
  <img src="/web_app/public/blackgate-logo.png" alt="Blackgate" width="500"/>
</p>

<p align="center">
  <strong>Open-source SRT Video Gateway</strong><br>
  <em>High-performance video routing with secure, reliable transport</em>
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#docker">Docker</a>
</p>

---

> ⚠️ **Pre-Alpha**: Early development stage. Features may be incomplete and breaking changes are expected.

## Features

### ✅ Current Features

| Category | Features |
|----------|----------|
| **SRT** | Listener, Caller, Rendezvous modes with authentication |
| **UDP** | Source and Destination support |
| **Dashboard** | Real-time system metrics (CPU, RAM, Load) |
| **Routes** | Create, edit, start, stop, delete with multiple destinations |
| **API** | Full REST API for programmatic control |
| **Deployment** | Docker support with backup/restore |

### 🚧 Planned

- Stream Statistics Display (bitrate, RTT, packet loss)
- SRT Destination Statistics
- Cluster Mode
- Dynamic Routing
- RTSP / RTMP / HLS / WebRTC

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    User Interface (React)                   │
│              Vite + Ant Design • Real-time Dashboard        │
└─────────────────────────────────────────────────────────────┘
                              │
                         REST API
                              │
┌─────────────────────────────────────────────────────────────┐
│                 Control Layer (Elixir)                      │
│        Route Management • Khepri Database • Metrics         │
└─────────────────────────────────────────────────────────────┘
                              │
                       Unix Socket
                              │
┌─────────────────────────────────────────────────────────────┐
│              Streaming Layer (C + GStreamer)                │
│         High-performance Video Routing • SRT/UDP            │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

```bash
# Ubuntu/Debian
sudo apt-get install libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
  libcjson-dev libsrt-dev libcmocka-dev libgio2.0-dev pkg-config

# macOS
brew install gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad \
  cjson srt cmocka pkg-config
```

Also requires: **Elixir** 1.17+, **Erlang/OTP** 27+, **Node.js** 18+

### Development

```bash
# Start backend + frontend
make dev-all
```

Access: `http://localhost:5173` • Login: `admin` / `password123`

## Docker

```bash
docker-compose build
docker-compose up
```

Access: `http://localhost:4000`

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `API_AUTH_USERNAME` | Auth username | (required) |
| `API_AUTH_PASSWORD` | Auth password | (required) |
| `PORT` | API port | 4000 |
| `DATABASE_DATA_DIR` | Database path | ./khepri |

## License

MIT
