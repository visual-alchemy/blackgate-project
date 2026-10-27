help:
	@make -qpRr | egrep -e '^[a-z].*:$$' | sed -e 's~:~~g' | sort

# Pinned toolchain installed by scripts/bootstrap_pinned_tools.sh. Exported to
# every recipe so targets also work in non-interactive/non-login shells, which
# never source ~/.bashrc or ~/.profile.
TOOLCHAIN := $(HOME)/.blackgate/toolchain
export PATH := $(TOOLCHAIN)/bin:$(TOOLCHAIN)/otp/bin:$(TOOLCHAIN)/elixir/bin:$(TOOLCHAIN)/node/bin:$(TOOLCHAIN)/rust/bin:$(PATH)
export ERL_ROOT := $(TOOLCHAIN)/otp

# =============================================================================
# BAREMETAL INSTALLATION TARGETS
# =============================================================================

.PHONY: install
install:
	@set -e; \
	echo "=============================================="; \
	echo "Step 0: Fresh host prerequisites"; \
	echo "=============================================="; \
	echo "This target installs everything the project builds against, but these must already"; \
	echo "exist, because they are needed before 'make' can run at all:"; \
	echo "  make   (package: make)      to invoke this target"; \
	echo "  git, or a copy of the repo  to get the code here"; \
	echo "  sudo + network              for the package-manager step below"; \
	echo "Bare Ubuntu 24.04 server:  sudo apt-get update && sudo apt-get install -y make git"; \
	echo "Step 3 needs no sudo: the pinned toolchains land in ~/.blackgate/toolchain."; \
	echo "Step 7 needs sudo once: it writes /etc/sysctl.d/90-blackgate.conf (SRT socket buffers)."; \
	echo ""; \
	if [ "$$(uname)" = "Linux" ] && command -v apt-get >/dev/null && ! command -v sudo >/dev/null; then \
		echo "ERROR: sudo is missing and the apt step needs it."; \
		exit 1; \
	fi; \
	echo "=============================================="; \
	echo "Step 1: Checking repository toolchain contract..."; \
	echo "=============================================="; \
	bash scripts/check_toolchain_contract.sh; \
	echo ""; \
	echo "=============================================="; \
	echo "Step 2: Installing Rust/GStreamer libraries..."; \
	echo "=============================================="; \
	if [ "$$(uname)" = "Linux" ]; then \
		if command -v apt-get > /dev/null; then \
			echo "Production baseline: Ubuntu 24.04 LTS"; \
			sudo add-apt-repository -y universe || true; \
			sudo apt-get update; \
			sudo apt-get install -y build-essential pkg-config git curl ca-certificates xz-utils unzip ripgrep ffmpeg procps \
				libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
				libgstreamer-plugins-bad1.0-dev gstreamer1.0-tools \
				gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
				gstreamer1.0-plugins-bad gstreamer1.0-libav \
				gstreamer1.0-vaapi libsrt-gnutls-dev libglib2.0-dev \
				libcjson-dev libgnutls28-dev nettle-dev libncurses6 libssl3t64; \
		elif command -v dnf > /dev/null; then \
			echo "Non-production Fedora/RHEL development host"; \
			sudo dnf install -y gcc gcc-c++ make pkgconfig git curl ffmpeg \
				gstreamer1-devel gstreamer1-plugins-base-devel \
				gstreamer1-plugins-good gstreamer1-plugins-bad-free \
				gstreamer1-plugins-bad-free-devel srt-devel glib2-devel; \
		else \
			echo "Unsupported Linux distribution. Please install dependencies manually."; \
			exit 1; \
		fi; \
	elif [ "$$(uname)" = "Darwin" ]; then \
		echo "Non-production macOS development host"; \
		brew install gstreamer srt glib pkg-config ffmpeg ripgrep || true; \
	else \
		echo "Unsupported OS. Please install dependencies manually."; \
		exit 1; \
	fi; \
	echo ""; \
	echo "=============================================="; \
	echo "Step 3: Bootstrapping pinned toolchains..."; \
	echo "=============================================="; \
	bash scripts/bootstrap_pinned_tools.sh; \
	echo ""; \
	echo "=============================================="; \
	echo "Step 4: Verifying pinned toolchains..."; \
	echo "=============================================="; \
	command -v mix >/dev/null || { echo "mix missing after bootstrap"; exit 1; }; \
	elixir --version | grep -q 'Elixir 1.18.2' || { echo "Elixir must be 1.18.2"; exit 1; }; \
	erl -noshell -eval 'io:format("~s", [erlang:system_info(system_version)]), halt().' | \
		grep -q 'Erlang/OTP 27 .*erts-15.0.1' || { echo "Erlang/OTP must be 27.0.1"; exit 1; }; \
	rustc --version | grep -q '^rustc 1.96.0 ' || { echo "Rust must be 1.96.0"; exit 1; }; \
	test "$$(node --version)" = "v20.19.0" || { echo "Node must be v20.19.0"; exit 1; }; \
	command -v rg >/dev/null || { echo "ripgrep missing (installed by step 2; expected on PATH for the project's tooling)"; exit 1; }; \
	echo "Toolchains verified."; \
	echo ""; \
	echo "=============================================="; \
	echo "Step 5: Installing Elixir Dependencies..."; \
	echo "=============================================="; \
	mix local.hex --force && \
	mix local.rebar --force && \
	mix deps.get; \
	echo ""; \
	echo "=============================================="; \
	echo "Step 6: Installing Frontend Dependencies..."; \
	echo "=============================================="; \
	npm --prefix web_app ci; \
	echo ""; \
	echo "=============================================="; \
	echo "Step 7: Raising socket buffers for SRT..."; \
	echo "=============================================="; \
	@# SRT needs large socket buffers. Without them the kernel drops datagrams at broadcast \
	@# bitrates and the failure looks like network loss - loss and retransmit climb, output \
	@# glitches, and nothing in the logs names the cause. The appliance ISO writes this file \
	@# in firstboot (/etc/sysctl.d/90-blackgate.conf); a `git clone` + `make install` host gets \
	@# it here, identically, so both install paths end in the same state. It goes in \
	@# /etc/sysctl.d/ on purpose: a bare `sysctl -w` would not survive a reboot. \
	if [ "$$(uname)" = "Linux" ]; then \
		want=16777216; \
		if command -v sudo >/dev/null 2>&1 && [ "$$(id -u)" != "0" ]; then as_root="sudo"; else as_root=""; fi; \
		if [ -w /etc/sysctl.d ] || [ -n "$$as_root" ]; then \
			if printf '%s\n' \
				"# Blackgate: SRT socket buffers. Written by 'make install' and by the appliance first boot." \
				"net.core.rmem_max=$$want" \
				"net.core.wmem_max=$$want" \
				| $$as_root tee /etc/sysctl.d/90-blackgate.conf >/dev/null; then \
				echo "  wrote /etc/sysctl.d/90-blackgate.conf"; \
				$$as_root sysctl --system >/dev/null 2>&1 \
					|| echo "  note: 'sysctl --system' failed - the values apply after a reboot or a re-run as root"; \
			else \
				echo "  could NOT write /etc/sysctl.d/90-blackgate.conf - read the check below"; \
			fi; \
		else \
			echo "  SKIPPED: no sudo and /etc/sysctl.d is not writable."; \
		fi; \
		rmem=$$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0); \
		wmem=$$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0); \
		echo "  now: net.core.rmem_max=$$rmem  net.core.wmem_max=$$wmem  (target >= $$want)"; \
		if [ "$$rmem" -lt "$$want" ] || [ "$$wmem" -lt "$$want" ]; then \
			echo ""; \
			echo "  WARNING: socket buffers are below the SRT target."; \
			echo "  SRT will lose datagrams at high bitrate and the logs will blame the network."; \
			echo "  Run this as root, then re-run 'make install':"; \
			echo "    sudo tee /etc/sysctl.d/90-blackgate.conf <<'EOF'"; \
			echo "    net.core.rmem_max=$$want"; \
			echo "    net.core.wmem_max=$$want"; \
			echo "    EOF"; \
			echo "    sudo sysctl --system"; \
			echo ""; \
		fi; \
	else \
		echo "  not Linux - set the equivalent of net.core.rmem_max/wmem_max manually"; \
	fi; \
	echo ""; \
	echo "=============================================="; \
	echo ""; \
	echo "=============================================="; \
	echo "Installation Complete!"; \
	echo "=============================================="; \
	echo "Next steps:"; \
	echo "  Development: make dev-all"; \
	echo "  Production:  make build && make start"


.PHONY: build
build:
	@echo "=============================================="
	@echo "Building Production Release..."
	@echo "=============================================="
	@echo ""
	@echo "Step 1: Building Frontend..."
	npm --prefix web_app run build
	@echo ""
	@echo "Step 2: Copying Frontend to Phoenix..."
	rm -rf priv/static
	mkdir -p priv/static
	cp -r web_app/dist/* priv/static/
	@echo ""
	@echo "Step 3: Building Elixir Release..."
	MIX_ENV=prod mix phx.digest
	rm -rf _build/prod/rel/blackgate
	@# Mix.Release.copy_erts intermittently dies with "could not change mode for
	@# _build/prod/rel/blackgate/erts-*/bin/erl: no such file or directory" while assembling the release
	@# in parallel tasks. It is a race in the assembler, not a permissions or disk problem, and a second
	@# attempt succeeds; retry once here instead of making every operator rediscover it.
	@MIX_ENV=prod mix release --overwrite || { \
		echo "release assembly failed (known copy_erts race) — retrying once..."; \
		rm -rf _build/prod/rel/blackgate; \
		MIX_ENV=prod mix release --overwrite; \
	}
	@test -d _build/prod/rel/blackgate/lib && ls _build/prod/rel/blackgate/lib | grep -q '^blackgate-' || { \
		echo "ERROR: release is incomplete — no blackgate app under _build/prod/rel/blackgate/lib."; \
		echo "       Booting it fails with load_failed for core modules. Recover with:"; \
		echo "       MIX_ENV=prod mix compile && MIX_ENV=prod mix release --overwrite"; \
		exit 1; }
	@echo "Release verified: blackgate app present, $$(ls _build/prod/rel/blackgate/lib | wc -l) applications"
	@echo ""
	@echo "=============================================="
	@echo "Build Complete!"
	@echo "=============================================="
	@echo "Start with: make start"

.PHONY: start
start:
	@# A gateway installed as a systemd unit has to be started through systemd. A manual node starts
	@# without BLACKGATE_ROOT (so the dashboard's update root falls back to /opt/blackgate) and without
	@# DATABASE_DATA_DIR, and while it holds port 4000 the unit sits in "activating" forever. Set
	@# BLACKGATE_ALLOW_MANUAL_START=1 only on a box that is deliberately not service-managed.
	@if [ "$${BLACKGATE_ALLOW_MANUAL_START:-0}" != "1" ] && [ -e /etc/systemd/system/blackgate.service ]; then \
		echo "blackgate.service is installed — this box runs the gateway under systemd."; \
		echo "  start it:  sudo systemctl start blackgate   (or the Restart button in Settings > System)"; \
		echo "  change it: make build, then deploy a package (scripts/package-signed-update.sh)"; \
		echo "  override:  BLACKGATE_ALLOW_MANUAL_START=1 make start"; \
		exit 1; \
	fi
	@if RELEASE_COOKIE=blackgate_production_cookie _build/prod/rel/blackgate/bin/blackgate pid > /dev/null 2>&1; then \
		echo "Blackgate is already running — run 'make stop' first."; \
		echo "(two nodes at once leave a stale /tmp/hydra_unix_sock behind; every engine then fails to connect with ECONNREFUSED and the routes crash-loop)"; \
		exit 1; \
	fi
	@rm -f /tmp/hydra_unix_sock
	@echo "Starting Blackgate in Production Mode..."
	PHX_SERVER=true \
	PORT=4000 \
	PHX_HOST=0.0.0.0 \
	API_AUTH_USERNAME=admin \
	API_AUTH_PASSWORD=password123 \
	LICENSE_SERVER_URL=https://license-server-eta-bay.vercel.app \
	RELEASE_COOKIE=blackgate_production_cookie \
	_build/prod/rel/blackgate/bin/blackgate daemon
	@echo "Waiting for Blackgate to become ready..."
	@for i in $$(seq 1 60); do \
		if RELEASE_COOKIE=blackgate_production_cookie _build/prod/rel/blackgate/bin/blackgate rpc \
			'IO.puts(inspect(Process.whereis(Blackgate.DynamicSupervisor) != nil and Process.whereis(Blackgate.RouteStatsRegistry) != nil))' \
			2>/dev/null | grep -q true; then \
			echo "Blackgate is ready (supervision tree up)."; \
			exit 0; \
		fi; \
		sleep 1; \
	done; \
	echo "ERROR: Blackgate did not report ready within 60s — the node answers RPC before its"; \
	echo "       supervision tree is up, so starting routes now fails with PartitionSupervisor"; \
	echo "       exits. Check the logs, then start routes once 'make start' reports ready."; \
	exit 1

.PHONY: stop
stop:
	@# Reverse of the guard in `start`: when the unit is what runs the gateway, `make stop` would
	@# report success while the service keeps serving.
	@if [ "$${BLACKGATE_ALLOW_MANUAL_START:-0}" != "1" ] && systemctl is-active --quiet blackgate.service 2>/dev/null; then \
		echo "blackgate.service is running this gateway — nothing for the Makefile to stop."; \
		echo "  stop it:   sudo systemctl stop blackgate"; \
		echo "  restart:   sudo systemctl restart blackgate   (or Settings > System)"; \
		exit 1; \
	fi
	@echo "Stopping Blackgate..."
	@RELEASE_COOKIE=blackgate_production_cookie \
	_build/prod/rel/blackgate/bin/blackgate stop || true
	@# A node started from a release directory that was later rebuilt (`make build`
	@# wipes _build/prod/rel/blackgate) can no longer be reached by
	@# `bin/blackgate stop` — its pid file went with the directory — and keeps the
	@# old engine binary loaded, so a "restart" silently kept running stale code.
	@# Kill any surviving release node by pid; `pgrep -x` cannot match this shell.
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		left=0; \
		for p in $$(pgrep -x beam.smp 2>/dev/null); do \
			if tr '\0' ' ' < /proc/$$p/cmdline 2>/dev/null | grep -q 'rel/blackgate'; then \
				left=1; kill $$p 2>/dev/null || true; \
			fi; \
		done; \
		[ $$left -eq 0 ] && break; \
		sleep 1; \
	done
	@echo "Blackgate stopped."

.PHONY: restart
restart: stop
	@# Wait for the node to actually release its name and stats socket: starting the
	@# new node while the old one is still shutting down fails with
	@# "name blackgate@dvls seems to be in use by another Erlang node".
	@for i in $$(seq 1 30); do \
		RELEASE_COOKIE=blackgate_production_cookie _build/prod/rel/blackgate/bin/blackgate pid > /dev/null 2>&1 || break; \
		sleep 1; \
	done
	@$(MAKE) start

.PHONY: status
status:
	@RELEASE_COOKIE=blackgate_production_cookie _build/prod/rel/blackgate/bin/blackgate pid > /dev/null 2>&1 && echo "Blackgate is running" || echo "Blackgate is not running"

# =============================================================================
# DEVELOPMENT TARGETS
# =============================================================================

.PHONY: dev
dev:
	MIX_ENV=dev \
	VAULT_ENC_KEY="12345678901234567890123456789012" \
	API_JWT_SECRET=dev \
	METRICS_JWT_SECRET=dev \
	VICTORIOMETRICS_HOST=localhost \
	VICTORIOMETRICS_PORT=8428 \
	API_AUTH_USERNAME=admin \
	API_AUTH_PASSWORD=password123 \
	ERL_AFLAGS="-kernel shell_history enabled +zdbbl 2097151" \
	ERL_COMPILER_OPTIONS=nowarn_deprecated_catch \
	iex --name blackgate@127.0.0.1 --cookie cookie -S mix phx.server --no-halt

.PHONY: dev-all
dev-all:
	@echo "Starting Blackgate (Backend + Frontend)..."
	@echo "Backend: http://localhost:4000"
	@echo "Frontend: http://localhost:5173"
	@npx concurrently -n "backend,frontend" -c "blue,green" \
		"make dev" \
		"cd web_app && npm run dev"

clean:
	rm -rf _build && rm -rf deps

setup:
	@echo "Installing Backend Dependencies..."
	mix local.hex --force
	mix local.rebar --force
	mix deps.get
	@echo "Installing Frontend Dependencies..."
	npm --prefix web_app ci

# =============================================================================
# TEST TARGETS
# =============================================================================

dev_udp0:
	ffmpeg -f lavfi -re -i smptebars=duration=6000:size=1280x720:rate=25 -f lavfi -re -i sine=frequency=1000:duration=6000:sample_rate=44100 \
	-pix_fmt yuv420p -c:v libx264 -b:v 1000k -g 25 -keyint_min 100 -profile:v baseline -preset veryfast \
	-f mpegts "udp://224.0.0.3:1234?pkt_size=1316"

dev_udp:
	ffmpeg -f lavfi -re -i smptebars=duration=6000:size=1280x720:rate=25 -f lavfi -re -i sine=frequency=1000:duration=6000:sample_rate=44100 \
	-pix_fmt yuv420p -c:v libx264 -b:v 1000k -g 25 -keyint_min 100 -profile:v baseline -preset veryfast \
	-f mpegts "srt://127.0.0.1:4201?mode=listener"	

dev_play:
	ffplay udp://224.0.0.3:1234

dev_play1:
	srt-live-transmit "srt://127.0.0.1:4201?mode=listener" udp://:1234 -v -statspf default -stats 1000

dev_udp1:
	ffmpeg -i "srt://127.0.0.1:4201?mode=caller" -f mpegts udp://239.0.0.1:1234?pkt_size=1316		

# =============================================================================
# DOCKER TARGETS
# =============================================================================

docker_restart:
	docker compose down && docker compose up -d

docker_ssh:
	docker compose exec blackgate bash

docker_logs:
	docker compose logs -f

docker_stop:
	docker compose down

docker_start:
	docker compose up -d

docker_clean:
	docker compose down && docker compose rm -f blackgate
