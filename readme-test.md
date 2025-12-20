# 🎥 SRT Gateway

![SERVER](https://img.shields.io/badge/SERVER-GATEWAY-gray?style=for-the-badge) ![Go](https://img.shields.io/badge/GO-1.21+-blue?style=for-the-badge&logo=go) ![PostgreSQL](https://img.shields.io/badge/POSTGRESQL-12+-blue?style=for-the-badge&logo=postgresql) ![Docker](https://img.shields.io/badge/DOCKER-ENABLED-cyan?style=for-the-badge&logo=docker)

**A production-ready, server-sided SRT Gateway web application for dynamic SRT Input-Output routing management**

[Features](#-features) • [Installation](#installation) • [Usage](#usage) • [Configuration](#configuration) • [Troubleshooting](#troubleshooting)

## ✨ Features

- 🎯 **Dynamic SRT Routing**: Manage SRT input and output streams with caller/listener modes
- 📊 **Live Monitoring**: Real-time connection status, bitrate, and dropped packet statistics
- 🟢 **Smart Status Indicators**: Frontend shows “Waiting Connection”, “Connected”, or manual-restart prompts based on live SRT state
- 🐳 **FFmpeg Integration**: Containerized FFmpeg processes for reliable stream relay
- 🌐 **Web Interface**: Clean, responsive web UI for stream management
- 🛰️ **Isolated Multicast Binding**: Pin the internal UDP multicast bridge to a dedicated NIC/IP for air-gapped monitor networks
- 🚀 **Production Ready**: Systemd service integration, PostgreSQL persistence, bare-metal deployment

## 🏗️ Architecture

- **Backend**: Go with gorilla/mux, database/sql, lib/pq, go-sqlite3
- **Database**: PostgreSQL or SQLite for persistent storage (auto-detected from DATABASE_URL)
- **SRT Engine**: FFmpeg in Docker containers (isolated per stream)
- **Frontend**: Static HTML/CSS/JS served by Go backend
- **Deployment**: Bare-metal systemd services (only FFmpeg dockerized)

## 🌐 Network Topology

### 📥 SRT Listener Workflow

```mermaid
graph TB
    subgraph "External Network"
        A["📹 SRT Source<br/>(Encoder/Camera)<br/>Mode: Caller"]
    end
    
    subgraph "SRT Gateway Server"
        subgraph "Web Interface"
            B["🌐 Web UI<br/>(HTML/CSS/JS)<br/>Port: 8080"]
        end
        
        subgraph "Go Backend"
            C["🔧 SRT Gateway Service<br/>(Go + gorilla/mux)<br/>REST API"]
            D["📊 Stats Manager<br/>(Real-time monitoring)"]
            E["🐳 Docker Service<br/>(Container management)"]
        end
        
        subgraph "Database"
            F["🗄️ PostgreSQL<br/>(Stream configs & stats)"]
        end
        
        subgraph "Docker Containers"
            G["📥 Input Container<br/>(FFmpeg + SRT)<br/>srt-input-{id}"]
            H["📤 Output Container 1<br/>(FFmpeg + SRT)<br/>srt-output-{id}"]
            I["📤 Output Container N<br/>(FFmpeg + SRT)<br/>srt-output-{id}"]
        end
        
        subgraph "Internal Network"
            J["🔄 UDP Multicast<br/>(239.255.0.1:port+10000)<br/>Bound to dedicated NIC via INTERNAL_UDP_LOCAL_ADDR"]
        end
    end
    
    subgraph "External Destinations"
        K["📺 SRT Destination 1<br/>(Player/Server)<br/>Mode: Listener"]
        L["📺 SRT Destination N<br/>(Player/Server)<br/>Mode: Caller"]
    end
    
    %% Data Flow
    A -->|"SRT Stream<br/>(TCP-like over UDP)"| G
    G -->|"Decoded MPEG-TS<br/>(UDP Multicast)"| J
    J -->|"MPEG-TS Stream"| H
    J -->|"MPEG-TS Stream"| I
    H -->|"SRT Stream<br/>(Re-encoded)"| K
    I -->|"SRT Stream<br/>(Re-encoded)"| L
    
    %% Control Flow
    B <-->|"HTTP/REST API"| C
    C <-->|"SQL Queries"| F
    C <-->|"Docker API"| E
    E -->|"Container Lifecycle"| G
    E -->|"Container Lifecycle"| H
    E -->|"Container Lifecycle"| I
    D -->|"Log Parsing"| G
    D -->|"Stats Collection"| F
    
    %% Styling
    classDef external fill:#1e3a8a,stroke:#3b82f6,stroke-width:3px,color:#ffffff
    classDef gateway fill:#581c87,stroke:#a855f7,stroke-width:3px,color:#ffffff
    classDef container fill:#166534,stroke:#22c55e,stroke-width:3px,color:#ffffff
    classDef database fill:#ea580c,stroke:#f97316,stroke-width:3px,color:#ffffff
    classDef network fill:#be185d,stroke:#ec4899,stroke-width:3px,color:#ffffff
    
    class A,K,L external
    class B,C,D,E gateway
    class G,H,I container
    class F database
    class J network
```

### 📤 SRT Caller Workflow

```mermaid
graph TB
    subgraph "SRT Gateway Server"
        subgraph "Web Interface"
            A["🌐 Web UI<br/>(HTML/CSS/JS)<br/>Port: 8080"]
        end
        
        subgraph "Go Backend"
            B["🔧 SRT Gateway Service<br/>(Go + gorilla/mux)<br/>REST API"]
            C["📊 Stats Manager<br/>(Real-time monitoring)"]
            D["🐳 Docker Service<br/>(Container management)"]
        end
        
        subgraph "Database"
            E["🗄️ PostgreSQL<br/>(Stream configs & stats)"]
        end
        
        subgraph "Docker Containers"
            F["📥 Input Container<br/>(FFmpeg + SRT)<br/>srt-input-{id}"]
            G["📤 Output Container 1<br/>(FFmpeg + SRT)<br/>srt-output-{id}"]
            H["📤 Output Container N<br/>(FFmpeg + SRT)<br/>srt-output-{id}"]
        end
        
        subgraph "Internal Network"
            I["🔄 UDP Multicast<br/>(239.255.0.1:port+10000)<br/>Bound to dedicated NIC via INTERNAL_UDP_LOCAL_ADDR"]
        end
    end
    
    subgraph "External Network"
        J["📹 SRT Source<br/>(Encoder/Camera)<br/>Mode: Listener"]
        K["📺 SRT Destination 1<br/>(Player/Server)<br/>Mode: Listener"]
        L["📺 SRT Destination N<br/>(Player/Server)<br/>Mode: Listener"]
    end
    
    %% Data Flow
    F -->|"SRT Connection<br/>(Outbound)"| J
    J -->|"SRT Stream<br/>(TCP-like over UDP)"| F
    F -->|"Decoded MPEG-TS<br/>(UDP Multicast)"| I
    I -->|"MPEG-TS Stream"| G
    I -->|"MPEG-TS Stream"| H
    G -->|"SRT Connection<br/>(Outbound)"| K
    H -->|"SRT Connection<br/>(Outbound)"| L
    
    %% Control Flow
    A <-->|"HTTP/REST API"| B
    B <-->|"SQL Queries"| E
    B <-->|"Docker API"| D
    D -->|"Container Lifecycle"| F
    D -->|"Container Lifecycle"| G
    D -->|"Container Lifecycle"| H
    C -->|"Log Parsing"| F
    C -->|"Stats Collection"| E
    
    %% Styling
    classDef external fill:#1e3a8a,stroke:#3b82f6,stroke-width:3px,color:#ffffff
    classDef gateway fill:#581c87,stroke:#a855f7,stroke-width:3px,color:#ffffff
    classDef container fill:#166534,stroke:#22c55e,stroke-width:3px,color:#ffffff
    classDef database fill:#ea580c,stroke:#f97316,stroke-width:3px,color:#ffffff
    classDef network fill:#be185d,stroke:#ec4899,stroke-width:3px,color:#ffffff
    
    class J,K,L external
    class A,B,C,D gateway
    class F,G,H container
    class E database
    class I network
```

### 🛠️ Technology Stack

| Component | Technology | Purpose |
|-----------|------------|----------|
| **Backend Framework** | Go 1.21+ with gorilla/mux | HTTP server and REST API |
| **Database** | PostgreSQL 12+ | Persistent storage for streams, stats, logs |
| **Database Driver** | lib/pq | PostgreSQL driver for Go |
| **Container Runtime** | Docker | Isolated FFmpeg processes |
| **Media Processing** | FFmpeg with SRT support | Stream transcoding and routing |
| **SRT Library** | Haivision SRT | Secure Reliable Transport protocol |
| **Frontend** | HTML5/CSS3/JavaScript | Web-based management interface |
| **Process Management** | systemd | Service lifecycle management |
| **Internal Routing** | UDP Multicast | Efficient 1-to-N stream distribution |
| **Monitoring** | Go routines + regex parsing | Real-time statistics collection |
| **Networking** | Host networking mode | Direct access to network interfaces |

### 🔄 Data Flow Details

#### Input Stream Processing
1. **SRT Reception**: FFmpeg receives SRT stream (caller connects to listener, or listener waits for caller)
2. **Decoding**: Stream is decoded to MPEG-TS format
3. **Internal Distribution**: MPEG-TS is sent to UDP multicast address (239.255.0.1:port+10000)
4. **Statistics**: FFmpeg logs are parsed for bitrate, FPS, dropped packets, connection status

#### Output Stream Processing
1. **Internal Reception**: FFmpeg receives MPEG-TS from UDP multicast
2. **SRT Transmission**: Stream is re-encoded and sent via SRT (caller connects to remote listener, or listener waits for remote caller)
3. **Multiple Outputs**: Each output stream runs in its own container, allowing different destinations

#### Management & Monitoring
1. **Web Interface**: Users configure streams via responsive web UI
2. **REST API**: Backend processes requests and manages Docker containers
3. **Database Persistence**: All configurations and statistics stored in PostgreSQL
4. **Real-time Updates**: Live statistics updated every 2 seconds via polling
5. **Container Health**: Automatic restart of failed containers with heartbeat monitoring (up to 10 attempts before requiring manual intervention) and UI badges that flip between “Waiting Connection”, “Connected”, or manual-restart guidance

## Installation

### 🚀 Quick Start (Recommended)

**One-command installation from fresh Ubuntu/Debian system:**

```bash
# Clone the repository
git clone https://github.com/your-repo/SRT-Gateway-Dockerization.git
cd SRT-Gateway-Dockerization

# Cache sudo credentials (avoids prompts during deploy)
sudo -v

# Run the automated deployment script
./scripts/deploy.sh
```

**That's it!** 🎉 The script will automatically:
- ✅ Install all system dependencies (PostgreSQL, Docker, Make)
- ✅ Check for Go installation (prompts if missing)
- ✅ Set up PostgreSQL database with proper permissions
- ✅ Apply all database migrations
- ✅ Build the Go application
- ✅ Create system user and directories
- ✅ Install systemd service
- ✅ Build custom FFmpeg Docker image with SRT support
- ✅ Test the installation
- ✅ Start the service

After installation, access the web interface at: **http://localhost:8080**

### Prerequisites

**System Requirements:**
- **RAM**: Minimum 2GB, recommended 4GB+
- **Disk Space**: At least 5GB free space
- **Network**: Internet connection for downloading dependencies
- **User**: Account with sudo privileges

**Supported Platforms:**
- ✅ **Ubuntu**: 18.04, 20.04, 22.04, 24.04
- ✅ **Debian**: 10 (Buster), 11 (Bullseye), 12 (Bookworm)
- ✅ **CentOS/RHEL**: 7, 8, 9
- ✅ **Rocky Linux**: 8, 9
- ✅ **AlmaLinux**: 8, 9
- ✅ **Fedora**: 35+
- ⚠️ **Other Linux**: May work but not officially tested

**Software Dependencies (Auto-installed):**
- Go 1.18+ (will be installed if missing)
- PostgreSQL 12+
- Docker CE
- Make and build tools
- FFmpeg with SRT support (via Docker)

**Network Requirements:**
- Ports 8080 (web interface) and your SRT ports must be available
- Firewall configured to allow necessary traffic

### 🛠️ Manual Development Setup

If you prefer manual setup or development:

1. **Clone and build**:
```bash
git clone https://github.com/your-repo/SRT-Gateway-Dockerization.git
cd SRT-Gateway-Dockerization
make deps
make build
```

2. **Start development database**:
```bash
make docker-dev
```

3. **Run migrations**:
```bash
make migrate
```

4. **Start the application**:
```bash
# Option 1: Use the startup script (recommended)
make start-dev
# or
./scripts/start-dev.sh

# Option 2: Manual start
make run
```

5. **Access the web interface**:
Open [http://localhost:8080](http://localhost:8080)

### 🔧 Service Management

After installation, manage the service with:

```bash
# Check service status
sudo systemctl status srt-gateway

# Start/stop/restart service
sudo systemctl start srt-gateway
sudo systemctl stop srt-gateway
sudo systemctl restart srt-gateway

# View logs
sudo journalctl -u srt-gateway -f

# Enable/disable auto-start
sudo systemctl enable srt-gateway
sudo systemctl disable srt-gateway
```

3. **Verify deployment**:
```bash
make status
make logs
```

### 🔄 Restarting Production

After server restart or to apply updates:

```bash
# Quick restart of all services
make start-prod

# Individual service management
make restart    # Restart SRT Gateway only
make status     # Check service status
make logs       # Monitor logs
```

## 📖 Usage

### 📥 Adding Input Streams

1. Click "Add Input Stream"
2. Configure:
   - **Stream Name**: Descriptive name
   - **Mode**: Caller (connects to remote) or Listener (waits for connections)
   - **IP Address**: Target IP (for caller) or bind IP (for listener)
   - **Port**: SRT port number
   - **Latency**: Buffer latency in milliseconds
   - **Buffer Size**: SRT buffer size in MB (1-16MB, default: 1MB)
   - **Encryption**: None, AES-128, AES-192, or AES-256
   - **Passphrase**: Required for encryption

### 📤 Adding Output Streams

1. Find your input stream
2. Click "Add Output" in the outputs section
3. Configure output parameters (similar to input)
4. Multiple outputs can be added per input

**Note**: Output streams automatically inherit the buffer size from their parent input stream when their own buffer size is set to 0 or left unspecified.

### 🎛️ Stream Control

- **▶️ Start**: Launches FFmpeg container for the stream
- **⏹️ Stop**: Stops and removes the FFmpeg container
- **📊 Stats**: View real-time statistics and logs
- **✏️ Edit**: Modify stream configuration
- **🗑️ Delete**: Remove stream (stops if running)

## 🔌 API Endpoints

### 📡 Streams
- `GET /api/v1/streams` - List all input streams with outputs
- `POST /api/v1/streams` - Create new stream
- `GET /api/v1/streams/{id}` - Get stream details
- `PUT /api/v1/streams/{id}` - Update stream
- `DELETE /api/v1/streams/{id}` - Delete stream

### 🎛️ Stream Control
- `POST /api/v1/streams/{id}/start` - Start stream
- `POST /api/v1/streams/{id}/stop` - Stop stream

### 📊 Monitoring
- `GET /api/v1/streams/{id}/stats` - Get stream statistics
- `GET /api/v1/streams/{id}/logs` - Get stream logs

## ⚙️ Configuration

### 🌍 Environment Variables

- `PORT`: HTTP server port (default: 8080)
- `DATABASE_URL`: Database connection string (supports PostgreSQL and SQLite)
  - PostgreSQL: `postgres://user:password@host/database?sslmode=disable`
  - SQLite: `sqlite://path/to/database.db`
- `DOCKER_HOST`: Docker daemon socket (default: unix:///var/run/docker.sock)
- `INTERNAL_UDP_LOCAL_ADDR`: Optional IPv4 address to bind the internal UDP multicast fan-out (useful when isolating traffic on a dedicated NIC such as `192.168.80.10`)

### 🗄️ Database Schema

The application uses three main tables:
- `streams`: Stream configurations and status
- `stream_stats`: Real-time statistics
- `stream_logs`: Debug and error logs

## 🐳 FFmpeg Integration

Each stream runs in an isolated Docker container using the `srt-gateway/ffmpeg:latest` image. The application:

1. **📥 Input Streams**: FFmpeg receives SRT and outputs to UDP for internal routing
2. **📤 Output Streams**: FFmpeg receives UDP input and outputs to SRT destinations
3. **📊 Monitoring**: Parses FFmpeg logs for statistics and connection status
4. **🔄 Lifecycle**: Manages container creation, monitoring, and cleanup

## 🎬 Understanding FFmpeg Commands

*For users who want to understand what happens behind the scenes*

When you create streams in the SRT Gateway, the system automatically generates FFmpeg commands to handle your video. Here's what these commands do in simple terms:

### 📥 **Receiving Video (Input Streams)**

When you set up an **Input Stream**, the system creates a command like this:

```bash
ffmpeg -i "srt://your-settings" -c copy "internal-routing"
```

**What this means:**
- `ffmpeg`: The video processing engine
- `-i "srt://your-settings"`: "Listen for video from this SRT address"
- `-c copy`: "Don't change the video quality, just pass it through"
- `"internal-routing"`: "Send the video to our internal system for distribution"

### 📤 **Sending Video (Output Streams)**

When you add an **Output Stream**, the system creates:

```bash
ffmpeg -i "internal-routing" -c copy "srt://destination"
```

**What this means:**
- `-i "internal-routing"`: "Take video from our internal system"
- `-c copy`: "Keep the same video quality"
- `"srt://destination"`: "Send it to this SRT destination"

### 🔧 **Important Settings Explained**

**Latency (Buffer Time):**
- Low latency (20-40ms): Near real-time, but less stable on poor networks
- High latency (200-2000ms): More stable, but delayed video

**Encryption:**
- None: Fastest, but video can be intercepted
- AES-128/192/256: Secure, but uses slightly more processing power

**Mode Types:**
- **Listener**: "Wait for someone to connect to me"
- **Caller**: "I will connect to someone else"

### 🌐 **Internal Routing Magic**

The gateway uses a clever trick called "UDP multicast" (address `239.255.0.1`) to efficiently copy your video to multiple destinations without using extra bandwidth or processing power.

**Think of it like this:**
- Input stream = "Video comes in through the front door"
- Internal routing = "Video gets copied in the hallway"
- Output streams = "Copies go out through different back doors"

### 🧷 Dedicated Multicast Interface

In production we often isolate the internal multicast onto a secondary NIC (for example `enp2s0` at `192.168.80.10/24`). By setting `INTERNAL_UDP_LOCAL_ADDR` to that IP, every FFmpeg container binds its internal `udp://239.255.0.1:(port+10000)` fan-out to the isolated interface. Operators can then plug monitoring gear (e.g., `192.168.80.11`) into the same switch and subscribe with VLC/FFmpeg without leaking traffic onto the primary LAN.

### 🛰️ Pinning Multicast to a Dedicated Interface

If you want the internal multicast (e.g., `udp://239.255.0.1:port+10000`) to egress only through a specific NIC:

1. Give the NIC a static IP (e.g., `enp2s0 → 192.168.80.10/24`).
2. Set `INTERNAL_UDP_LOCAL_ADDR=192.168.80.10` in the `srt-gateway` systemd unit and reload/restart the service.
3. Downstream tools can bind to their own address when subscribing, e.g.:
   ```bash
   ffmpeg -i "udp://@239.255.0.1:15000?localaddr=192.168.80.10&fifo_size=1048576&overrun_nonfatal=1" -f null -
   ```
   or from another host on the same subnet:
   ```
   udp://@239.255.0.1:15000?localaddr=192.168.80.11
   ```

This confines multicast traffic to the isolated VLAN/switch attached to that NIC and keeps the main office LAN clean.

### 🎯 **Why This Matters**

- **Efficiency**: One input can feed many outputs without extra work
- **Quality**: Video passes through without being re-encoded (no quality loss)
- **Reliability**: Each output runs independently - if one fails, others keep working
- **Monitoring**: The system can track each connection separately

*You don't need to understand these details to use the gateway, but they explain why it's so efficient and reliable!*

## 🔒 Security Considerations

- Application runs as dedicated user with minimal privileges
- Docker containers are isolated and ephemeral
- Database connections use dedicated user with limited permissions
- No external dependencies or SaaS integrations
- All traffic stays within your infrastructure

## 🔧 Monitoring and Maintenance

### 🛠️ Service Management
```bash
# Check status
sudo systemctl status srt-gateway

# View logs
sudo journalctl -u srt-gateway -f

# Restart service
sudo systemctl restart srt-gateway
```

### 🗄️ Database Maintenance
```bash
# Connect to database
psql -h localhost -U srtgateway -d srtgateway

# View active streams
SELECT name, status, ip_address, port FROM streams WHERE status = 'running';

# Clean old statistics (optional)
DELETE FROM stream_stats WHERE timestamp < NOW() - INTERVAL '7 days';
```

### 🐳 Docker Cleanup
```bash
# Remove stopped containers
docker container prune

# View running SRT containers
docker ps --filter "name=srt-"
```

## 🔍 Troubleshooting

### 🚨 Installation Issues

**Script fails with permission errors:**
```bash
# Ensure you have sudo privileges
sudo -v

# Make script executable
chmod +x scripts/deploy.sh
```

**Go installation fails:**
```bash
# Manual Go installation
wget https://go.dev/dl/go1.21.0.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.0.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
source ~/.bashrc
```

**PostgreSQL connection issues:**
```bash
# Check PostgreSQL status
sudo systemctl status postgresql

# Restart PostgreSQL
sudo systemctl restart postgresql

# Test connection
psql -h localhost -U srtgateway -d srtgateway -c "SELECT version();"
```

**Docker daemon not running:**
```bash
# Start Docker service
sudo systemctl start docker
sudo systemctl enable docker

# Add user to docker group (logout/login required)
sudo usermod -aG docker $USER
```

### ⚠️ Runtime Issues

**Service won't start:**
```bash
# Check service status and logs
sudo systemctl status srt-gateway
sudo journalctl -u srt-gateway -n 50

# Check if port 8080 is available
sudo netstat -tlnp | grep :8080

# Restart service
sudo systemctl restart srt-gateway
```

**Stream won't start:**
```bash
# Check Docker daemon
sudo systemctl status docker

# Verify FFmpeg image exists
docker images | grep ffmpeg-srt

# Rebuild FFmpeg image if missing
docker build -f Dockerfile.ffmpeg -t ffmpeg-srt .

# Check container logs
docker logs srt-input-{stream-id}
```

**Connection/Network issues:**
```bash
# Check firewall (Ubuntu/Debian)
sudo ufw status
sudo ufw allow 8080
sudo ufw allow {your-srt-port}

# Check firewall (CentOS/RHEL/Rocky/Alma)
sudo firewall-cmd --list-all
sudo firewall-cmd --add-port=8080/tcp --permanent
sudo firewall-cmd --add-port={your-srt-port}/udp --permanent
sudo firewall-cmd --reload

# Test network connectivity
telnet {target-ip} {srt-port}
ping {target-ip}
```

**High CPU/Memory usage:**
```bash
# Monitor system resources
top -p $(pgrep -d, -f srt-gateway)

# Check Docker container resources
docker stats --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}"

# Limit concurrent streams or reduce quality settings
```

**Database errors:**
```bash
# Check PostgreSQL logs
sudo journalctl -u postgresql -n 50

# Verify database exists and permissions
sudo -u postgres psql -c "\l" | grep srtgateway
sudo -u postgres psql -c "\du" | grep srtgateway

# Re-run migrations if needed
cd /opt/srt-gateway && ./srt-gateway -migrate
```

### 🐛 Debug Mode

**Enable verbose application logging:**
```bash
# Edit systemd service for debug mode
sudo systemctl edit srt-gateway
# Add: Environment="LOG_LEVEL=debug"

# Restart service
sudo systemctl restart srt-gateway

# Monitor logs in real-time
sudo journalctl -u srt-gateway -f
```

**FFmpeg container debugging:**
```bash
# View specific container logs
docker logs srt-input-{stream-id}

# Monitor all SRT containers
docker logs -f $(docker ps -q --filter "name=srt-")

# Execute shell in running container
docker exec -it srt-input-{stream-id} /bin/bash
```

### 🔧 Platform-Specific Notes

**CentOS/RHEL 7:**
- Requires EPEL repository for some packages
- May need to update Docker to newer version
- SELinux may require additional configuration

**Fedora:**
- Uses `dnf` package manager (automatically detected)
- Firewall uses `firewalld` by default

**Debian:**
- May require `sudo apt update` before installation
- Some packages may have different names

### 📞 Getting Help

1. **Check logs first**: `sudo journalctl -u srt-gateway -n 100`
2. **Verify system requirements**: Run `./scripts/test-deploy.sh`
3. **Test network connectivity**: Ensure ports are open and accessible
4. **Check Docker**: Verify Docker daemon is running and accessible
5. **Database connectivity**: Test PostgreSQL connection and permissions

**For persistent issues:**
- Include full error messages and logs
- Specify your Linux distribution and version
- Describe your network setup and firewall configuration
- List any custom modifications made to the installation

## 📄 License

This project is licensed under the MIT License.
