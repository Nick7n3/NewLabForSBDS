.PHONY: all docker dev setup build-wasm build check clean

# ── Docker (recommended, handles everything) ──────────────────────────────────
docker:
	docker compose up --build

docker-down:
	docker compose down -v

# ── One-time setup ────────────────────────────────────────────────────────────
setup:
	rustup target add wasm32-unknown-unknown
	cargo install trunk --locked

# ── Development (hot-reload frontend + backend) ───────────────────────────────
# Terminal 1: start databases (postgres + mongo)
# Terminal 2: make dev-cnc
# Terminal 3: make dev-client
# Terminal 4: make dev-frontend   ← Trunk watches & rebuilds WASM
dev-cnc:
	CNC_PORT=9000 MONGO_URL=mongodb://localhost:27017 \
	  cargo run --package cnc

dev-client:
	DATABASE_URL=postgres://postgres:postgres@localhost:5432/cynosure \
	CLIENT_PORT=8080 CNC_URL=http://localhost:9000 \
	JWT_SECRET=dev-secret-32-chars-minimum-pad! \
	HMAC_KEY=dev-hmac-key-32-chars-minimum-pad \
	  cargo run --package client

dev-frontend:
	cd frontend && trunk serve --port 3000 \
	  --proxy-backend=http://localhost:8080

# Run a single agent
agent:
	CNC_URL=http://localhost:9000 cargo run --package agent

# ── Production builds ─────────────────────────────────────────────────────────
build-wasm:
	cd frontend && trunk build --release

build: build-wasm
	cargo build --release --package client --package cnc --package agent

check:
	cargo check --workspace --exclude frontend
	cargo check --package frontend --target wasm32-unknown-unknown

clean:
	cargo clean
	rm -rf frontend/dist
