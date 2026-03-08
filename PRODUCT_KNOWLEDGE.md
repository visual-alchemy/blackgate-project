# Blackgate — Product Knowledge Base

## Product Overview
Blackgate (formerly Hydra SRT) is a high-performance, containerized SRT (Secure Reliable Transport) gateway and routing engine. It receives live video streams (via SRT or UDP) and routes them to multiple destinations (SRT or UDP multicast) efficiently without transcoding the underlying video. 

Built on the Erlang/BEAM VM using Elixir, it features a native C pipeline engine powered by GStreamer for maximum performance and minimal latency.

## Core Value Proposition
- **Ultra-low latency routing**: Uses native C bindings and GStreamer's `tsparse` to demux and remux streams without the CPU overhead of transcoding.
- **High concurrency**: Leverages OTP supervision trees to run thousands of isolated stream pipelines on a single server. Crash in one stream does not affect others.
- **Embedded fault-tolerant database**: Uses Khepri (Raft consensus) right inside the BEAM VM for storing route configuration, removing the need for an external SQL database.
- **Real-time observability**: Built-in stats extraction from MPEG-TS streams, pushed continuously to VictoriaMetrics/InfluxDB.

## Recent Feature Additions (Latest First)

### 1. UI/UX Quick Wins
- **Bulk Start/Stop**: Manage multiple routes simultaneously using table checkboxes and a single click.
- **Route Cloning**: Instantly duplicate complex route configurations including all their multi-destinations.
- **Filter Persistence**: Search and filter settings (status, schema, text) remember their state across page navigation.
- **Dual Save Buttons**: "Save and Continue" vs "Save and Exit" when editing routes.

### 2. Seamless Auto-Restart
Editing a running route's configuration (or its destinations) seamlessly restarts the native pipeline in the background applying the new config without requiring manual stop/start clicks. 

### 3. Machine Locking & Anti-Tampering (Planned)
Future license enforcement will integrate dmidecode (UUID, Serial, MAC) to lock licenses to specific baremetal hardware.

### 4. Baremetal ISO Installer (Planned)
Future distribution method packaging Debian Bookworm + Blackgate + Docker into a self-installing ISO using Preseed, allowing customers to install the entire appliance from a USB drive in 5 minutes.

## Target Audience
- Broadcasters and media companies needing reliable point-to-point or point-to-multipoint video contribution over the public internet.
- Esports and live event producers needing ultra-low latency remote production.
- Cloud video infrastructure providers needing an edge ingest gateway.
