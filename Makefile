help:
	@make -qpRr | egrep -e '^[a-z].*:$$' | sed -e 's~:~~g' | sort

# =============================================================================
# BAREMETAL INSTALLATION TARGETS
# =============================================================================

.PHONY: install
install:
	@echo "=============================================="
	@echo "Step 1: Installing System Libraries..."
	@echo "=============================================="
	@if [ "$$(uname)" = "Linux" ]; then \
		if command -v apt-get > /dev/null; then \
			echo "Detected Debian/Ubuntu..."; \
			sudo add-apt-repository -y universe || true; \
			sudo apt-get update; \
			sudo apt-get install -y build-essential pkg-config git curl wget \
				libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
				gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
				libcjson-dev libsrt-openssl-dev libcmocka-dev libglib2.0-dev; \
		elif command -v dnf > /dev/null; then \
			echo "Detected Fedora/RHEL..."; \
			sudo dnf install -y gcc make pkgconfig git curl wget \
				gstreamer1-devel gstreamer1-plugins-base-devel \
				gstreamer1-plugins-good gstreamer1-plugins-bad-free \
				cjson-devel srt-devel cmocka-devel glib2-devel; \
		else \
			echo "Unsupported Linux distribution. Please install dependencies manually."; \
			exit 1; \
		fi; \
	elif [ "$$(uname)" = "Darwin" ]; then \
		echo "Detected macOS..."; \
		brew install gstreamer cjson srt cmocka glib pkg-config || true; \
	else \
		echo "Unsupported OS. Please install dependencies manually."; \
		exit 1; \
	fi
	@echo ""
	@echo "=============================================="
	@echo "Step 2: Installing Node.js & Yarn..."
	@echo "=============================================="
	@if [ "$$(uname)" = "Linux" ]; then \
		if ! command -v node > /dev/null; then \
			echo "Installing Node.js..."; \
			curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - || true; \
			sudo apt-get install -y nodejs || sudo dnf install -y nodejs; \
		else \
			echo "Node.js already installed: $$(node --version)"; \
		fi; \
		if ! command -v yarn > /dev/null; then \
			echo "Installing Yarn..."; \
			sudo npm install --global yarn --force; \
		else \
			echo "Yarn already installed: $$(yarn --version)"; \
		fi; \
	elif [ "$$(uname)" = "Darwin" ]; then \
		brew install node yarn || true; \
	fi
	@echo ""
	@echo "=============================================="
	@echo "Step 3: Installing Elixir & Erlang..."
	@echo "=============================================="
	@if [ "$$(uname)" = "Linux" ]; then \
		if ! command -v elixir > /dev/null; then \
			echo "Installing Elixir and Erlang..."; \
			if command -v apt-get > /dev/null; then \
				echo "Trying Ubuntu/Debian native packages first..."; \
				sudo apt-get install -y erlang elixir 2>/dev/null || \
				( \
					echo "Native packages failed, trying erlang-solutions repo..."; \
					wget -q https://binaries2.erlang-solutions.com/ubuntu/pool/contrib/e/esl-erlang/esl-erlang_26.2.5.2-1~ubuntu~jammy_amd64.deb -O /tmp/erlang.deb && \
					sudo dpkg -i /tmp/erlang.deb || sudo apt-get install -f -y && \
					sudo apt-get install -y elixir && \
					rm -f /tmp/erlang.deb \
				) || \
				( \
					echo "Falling back to apt repository..."; \
					sudo apt-get install -y software-properties-common && \
					sudo add-apt-repository -y ppa:rabbitmq/rabbitmq-erlang && \
					sudo apt-get update && \
					sudo apt-get install -y erlang elixir \
				); \
			elif command -v dnf > /dev/null; then \
				sudo dnf install -y erlang elixir; \
			fi; \
		else \
			echo "Elixir already installed: $$(elixir --version | head -1)"; \
		fi; \
	elif [ "$$(uname)" = "Darwin" ]; then \
		brew install elixir || true; \
	fi
	@echo ""
	@echo "=============================================="
	@echo "Step 4: Installing Elixir Dependencies..."
	@echo "=============================================="
	mix local.hex --force
	mix local.rebar --force
	mix deps.get
	@echo ""
	@echo "=============================================="
	@echo "Step 5: Installing Frontend Dependencies..."
	@echo "=============================================="
	cd web_app && yarn install
	@echo ""
	@echo "=============================================="
	@echo "Installation Complete!"
	@echo "=============================================="
	@echo "Next steps:"
	@echo "  Development: make dev-all"
	@echo "  Production:  make build && make start"


.PHONY: build
build:
	@echo "=============================================="
	@echo "Building Production Release..."
	@echo "=============================================="
	@echo ""
	@echo "Step 1: Building Frontend..."
	cd web_app && yarn build
	@echo ""
	@echo "Step 2: Copying Frontend to Phoenix..."
	rm -rf priv/static/assets
	cp -r web_app/dist/* priv/static/
	@echo ""
	@echo "Step 3: Building Elixir Release..."
	MIX_ENV=prod mix assets.deploy
	MIX_ENV=prod mix release --overwrite
	@echo ""
	@echo "=============================================="
	@echo "Build Complete!"
	@echo "=============================================="
	@echo "Start with: make start"

.PHONY: start
start:
	@echo "Starting Blackgate in Production Mode..."
	PHX_SERVER=true \
	PORT=4000 \
	PHX_HOST=0.0.0.0 \
	API_AUTH_USERNAME=admin \
	API_AUTH_PASSWORD=password123 \
	_build/prod/rel/blackgate/bin/blackgate start

.PHONY: stop
stop:
	@echo "Stopping Blackgate..."
	_build/prod/rel/blackgate/bin/blackgate stop || true

.PHONY: restart
restart: stop start

.PHONY: status
status:
	@_build/prod/rel/blackgate/bin/blackgate pid > /dev/null 2>&1 && echo "Blackgate is running" || echo "Blackgate is not running"

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
	iex --name blackgate@127.0.0.1 --cookie cookie -S mix phx.server --no-halt

.PHONY: dev-all
dev-all:
	@echo "Starting Blackgate (Backend + Frontend)..."
	@echo "Backend: http://localhost:4000"
	@echo "Frontend: http://localhost:5173"
	@npx concurrently -n "backend,frontend" -c "blue,green" \
		"make dev" \
		"cd web_app && yarn dev"

clean:
	rm -rf _build && rm -rf deps

setup:
	@echo "Installing Backend Dependencies..."
	mix local.hex --force
	mix local.rebar --force
	mix deps.get
	@echo "Installing Frontend Dependencies..."
	cd web_app && yarn install

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
