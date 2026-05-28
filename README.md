# CYNOSURE — Control Panel

Cyberpunk-styled C2 lab toolkit.  
**Full Rust stack**: Leptos/WASM frontend, Axum backends, PostgreSQL + MongoDB.  
Zero JavaScript — the entire UI is compiled Rust running in WebAssembly.

```
Agent(s) ──heartbeat──► C&C  (Axum + MongoDB  :9000)
                              │  sync every 15s
                         Client (Axum + PostgreSQL :8080)
                              │  serves static files
                         Browser ← WASM (Leptos, compiled from Rust)
```

---

## Quick Start — Docker (recommended)

```bash
cp .env.example .env          # edit secrets if desired
docker compose up --build     # builds WASM then backend, starts everything
```

Open **http://localhost:8080**  
Default login: `admin` / `admin`

> The Docker build compiles the Leptos frontend to WASM with `trunk`,
> then builds the Axum server, and bundles them in a single image.
> No JavaScript is shipped — only `.wasm` + the HTML shell.

---

## Local Development

### Prerequisites

```bash
# Install Rust targets and trunk (once)
rustup target add wasm32-unknown-unknown
cargo install trunk --locked

# Start PostgreSQL and MongoDB however you prefer, then:
cp .env.example .env
```

### Four terminals

```bash
# 1 — C&C server
make dev-cnc

# 2 — Client backend  
make dev-client

# 3 — Frontend (trunk watches, rebuilds WASM on save, proxies /api to :8080)
make dev-frontend        # open http://localhost:3000

# 4 — One or more agents
make agent               # copy binary to different dirs for multiple agents
```

### Production build

```bash
make build        # runs trunk build --release then cargo build --release
```

---

## Project Structure

```
cynosure/
├── common/          Shared types (AgentRecord, Heartbeat, ApiResponse…)
├── agent/           Heartbeat-only binary; persists UID to .cynosure_agent_uid
├── cnc/             Axum + MongoDB; receives heartbeats, tracks status
├── client/          Axum backend; syncs from C&C, serves WASM frontend
│   └── src/
│       ├── auth.rs       JWT middleware
│       ├── db.rs         PostgreSQL pool + inline migrations + Argon2id
│       ├── sync.rs       Background C&C poller (15 s)
│       └── routes/       agents, users, logs, auth
└── frontend/        Leptos 0.6 CSR app (compiles to WASM)
    ├── src/
    │   ├── main.rs       App root + tab routing (pure Rust, no JS)
    │   ├── api.rs        HTTP calls via gloo-net
    │   ├── logo.rs       CYNOSURE SVG generated as Rust string
    │   ├── state.rs      AuthState, UiState, Tab enum
    │   ├── types.rs      Serde types matching backend API
    │   └── components/
    │       ├── auth.rs       Login screen
    │       ├── nav.rs        Topbar + live clock (js_sys::Date)
    │       ├── dashboard.rs  Stats + agent card grid
    │       ├── agents.rs     CRUD table + add/rename modals
    │       ├── users.rs      Operator management
    │       └── logs.rs       Filterable audit log + HMAC verify
    ├── style.css      All styling (cyberpunk amber-on-dark theme)
    ├── index.html     WASM mount shell (trunk entry point)
    └── Trunk.toml     Trunk build config
```

---

## Features

| Feature | Notes |
|---|---|
| **Zero JS frontend** | Leptos 0.6 CSR compiled to WASM; only Rust runs in browser |
| **Login / JWT** | Argon2id passwords, HS256 JWT (24 h), role-checked per endpoint |
| **Roles** | `admin` (all), `read_write` (agents), `read_only` (view) |
| **Agent registry** | Add (ID-AXXXX format), rename, remove |
| **C&C sync** | Background task polls C&C every 15 s, upserts into PostgreSQL |
| **Audit logs** | Every write action logged with HMAC-SHA256 per entry |
| **Integrity check** | `/api/logs/verify` re-computes all HMACs, reports tampered rows |
| **SQL injection** | All queries parameterised; usernames validated by regex |
| **CYNOSURE logo** | SVG generated entirely in Rust (`logo.rs`), injected via `inner_html` |

---

## Agent UID

- Generated from UUID v4 bytes on first run, formatted `ID-AXXXX`
- Persisted to `.cynosure_agent_uid` **next to the binary**
- Unique per binary instance — not per machine, terminal, or user
- Deploy multiple agents: copy the binary to separate directories

---

## Environment Variables

| Variable | Default | Component |
|---|---|---|
| `DATABASE_URL` | `postgres://postgres:postgres@localhost:5432/cynosure` | client |
| `CLIENT_PORT` | `8080` | client |
| `JWT_SECRET` | *(weak default — change it!)* | client |
| `HMAC_KEY` | *(weak default — change it!)* | client |
| `CNC_URL` | `http://localhost:9000` | client + agent |
| `MONGO_URL` | `mongodb://localhost:27017` | cnc |
| `CNC_PORT` | `9000` | cnc |
