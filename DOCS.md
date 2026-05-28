# CYNOSURE Control Panel — Technical Documentation

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Component Breakdown](#2-component-breakdown)
3. [Database Schema](#3-database-schema)
4. [API Reference](#4-api-reference)
5. [Agent Protocol](#5-agent-protocol)
6. [Security Model](#6-security-model)
7. [Frontend Architecture](#7-frontend-architecture)
8. [Configuration Reference](#8-configuration-reference)
9. [Deployment](#9-deployment)
10. [Development Guide](#10-development-guide)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Architecture Overview

```
┌─────────────┐        heartbeat (HTTP POST)        ┌─────────────────────┐
│   Agent(s)  │ ──────────────────────────────────► │  C&C Server         │
│  (Rust bin) │  {uid, geo, os, hostname}           │  (Axum + MongoDB)   │
└─────────────┘                                     └──────────┬──────────┘
                                                               │
                                                    GET /api/sync  every 15s
                                                               │
                                                    ┌──────────▼──────────┐
                                                    │  Client Server      │
                                                    │  (Axum + PostgreSQL)│
                                                    └──────────┬──────────┘
                                                               │
                                                    serves compiled WASM
                                                               │
                                                    ┌──────────▼──────────┐
                                                    │  Browser            │
                                                    │  (Leptos WASM, 0 JS)│
                                                    └─────────────────────┘
```

**Key design decisions:**

- Agents never contact the Client directly. They only talk to C&C.
- Client pulls from C&C on a 15-second poll cycle; agents are never pushed to.
- The browser runs compiled Rust (WebAssembly). Zero JavaScript is shipped.
- C&C is intentionally minimal (PoC). It stores only what agents report.
- Client is the single source of truth for the operator — it owns PostgreSQL.

---

## 2. Component Breakdown

### 2.1 Agent (`agent/`)

| File | Purpose |
|---|---|
| `src/main.rs` | Entry point, UID persistence, heartbeat loop |
| `build.rs` | Injects `CNC_URL` at compile time via `env!()` |
| `Cargo.toml` | Release profile: `opt-level=z`, `lto=true`, `strip=true` |

**What it does:**
1. On first run, generates a unique `ID-AXXXX` UID (hashed from UUID v4 bytes) and writes it to `.cynosure_agent_uid` next to the binary.
2. Detects OS via `std::env::consts::OS` and hostname via `$HOSTNAME` env or `/etc/hostname`.
3. Derives a deterministic-but-varied geo position from the UID hash (lab use only).
4. Sends a heartbeat `POST /api/heartbeat` to C&C every 10 seconds.
5. Logs the ACK UID to stdout.

**UID format:** `ID-A` followed by 4 decimal digits (0000–9999), e.g. `ID-A0042`.  
The number comes from `uuid_v4_bytes[0..3]` interpreted as a 24-bit integer mod 10000, then formatted. This gives ~10 000 distinct values — sufficient for a lab.

**To deploy multiple agents:** copy the compiled binary to separate directories. Each directory gets its own `.cynosure_agent_uid` file on first run.

---

### 2.2 C&C (`cnc/`)

| File | Purpose |
|---|---|
| `src/main.rs` | Axum server setup with `ConnectInfo` for IP detection |
| `src/db.rs` | MongoDB connection |
| `src/routes.rs` | `POST /api/heartbeat`, `GET /api/agents`, `GET /api/sync` |

**MongoDB collection: `agents`**

```json
{
  "uid":      "ID-A0042",
  "name":     "ID-A0042",
  "last_seen": "2024-01-01T12:00:00.000000Z",
  "status":   "active",
  "geo":      { "lat": "55.751244", "lon": "37.618423" },
  "os":       "linux",
  "hostname": "kali-vm",
  "last_ip":  "172.20.0.5"
}
```

**Status logic:** C&C marks an agent `active` if `now - last_seen < 30 seconds`, otherwise `offline`. This is computed fresh on every `/api/sync` and `/api/agents` response — it is never stored in MongoDB.

---

### 2.3 Client (`client/`)

| File | Purpose |
|---|---|
| `src/main.rs` | Axum server, route registration, background sync spawn |
| `src/db.rs` | PostgreSQL pool, inline migrations, Argon2id helpers, audit log re-sign |
| `src/auth.rs` | JWT middleware (`require_auth`), token creation/decoding |
| `src/sync.rs` | Background task: pulls C&C `/api/sync` every 15 s, upserts into PostgreSQL |
| `src/routes/auth.rs` | `POST /api/auth/login` |
| `src/routes/agents.rs` | CRUD for agents + geo normalisation |
| `src/routes/users.rs` | CRUD for users |
| `src/routes/logs.rs` | Audit log query + HMAC verification |
| `src/routes/totp.rs` | TOTP setup and password-change endpoints |

---

### 2.4 Frontend (`frontend/`)

| File | Purpose |
|---|---|
| `src/lib.rs` | WASM entry point (`#[wasm_bindgen(start)]`), `App` root component |
| `src/state.rs` | `AuthState`, `UiState`, `Tab` enum |
| `src/types.rs` | Serde types matching the backend JSON API |
| `src/api.rs` | All HTTP calls via `gloo-net` |
| `src/logo.rs` | CYNOSURE SVG logo generated as a Rust string |
| `src/components/auth.rs` | Login screen + TOTP change-password screen |
| `src/components/nav.rs` | Topbar with live clock |
| `src/components/dashboard.rs` | Stats cards + agent card grid |
| `src/components/agents.rs` | Full CRUD table + add/edit modal |
| `src/components/users.rs` | Operator management + TOTP setup modal |
| `src/components/logs.rs` | Filterable audit log + integrity verification |
| `style.css` | All styling (cyberpunk amber-on-dark, CRT scanlines) |
| `index.html` | Trunk entry point — WASM mount shell, no JS |

---

## 3. Database Schema

### 3.1 PostgreSQL (Client)

```sql
-- Users / operators
CREATE TABLE users (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    username      TEXT        NOT NULL UNIQUE,
    password_hash TEXT        NOT NULL,           -- Argon2id
    role          TEXT        NOT NULL DEFAULT 'read_only',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    totp_secret   TEXT                            -- NULL = TOTP not configured
);

-- Agents (synced from C&C + manual additions)
CREATE TABLE agents (
    uid        TEXT        PRIMARY KEY,
    name       TEXT        NOT NULL,
    status     TEXT        NOT NULL DEFAULT 'offline',
    last_seen  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    lat        TEXT,                              -- Decimal degrees or NULL
    lon        TEXT,
    geo_locked BOOLEAN     NOT NULL DEFAULT false,-- TRUE = operator-set, sync won't overwrite
    os         TEXT,                              -- linux / windows / macos
    hostname   TEXT,
    last_ip    TEXT                               -- IP as seen by C&C
);

-- Audit trail
CREATE TABLE audit_logs (
    id        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    username  TEXT        NOT NULL,
    action    TEXT        NOT NULL,
    target    TEXT        NOT NULL DEFAULT '',
    details   TEXT        NOT NULL DEFAULT '',
    hmac      TEXT        NOT NULL DEFAULT ''     -- HMAC-SHA256 of the row
);

-- Indexes
CREATE INDEX idx_al_ts  ON audit_logs(timestamp DESC);
CREATE INDEX idx_al_usr ON audit_logs(username);
CREATE INDEX idx_al_act ON audit_logs(action);
```

**Roles stored as plain text:** `admin`, `read_write`, `read_only`.  
**geo_locked flag:** When an operator manually sets lat/lon through the UI, `geo_locked` is set to `true`. The sync task's `CASE WHEN agents.geo_locked THEN agents.lat ELSE ...` clause will never overwrite it with heartbeat data again.

### 3.2 MongoDB (C&C)

**Database:** `cynosure_cnc`  
**Collection:** `agents`

No schema enforcement — documents are upserted by UID on every heartbeat. All fields except `uid` and `last_seen` are optional (may be missing for agents that connected before an update).

---

## 4. API Reference

All endpoints return `application/json` in this envelope:

```json
{ "ok": true,  "data": <payload>, "error": null  }
{ "ok": false, "data": null,      "error": "message" }
```

### 4.1 Auth

#### `POST /api/auth/login`
No authentication required.

**Request:**
```json
{ "username": "admin", "password": "admin" }
```

**Response `200`:**
```json
{
  "ok": true,
  "data": {
    "token":    "eyJ...",
    "username": "admin",
    "role":     "admin"
  }
}
```

**Response `200` (bad credentials):**
```json
{ "ok": false, "data": null, "error": "Invalid credentials" }
```

The token is a **HS256 JWT** signed with `JWT_SECRET`. Expiry: 24 hours.  
Payload: `{ "sub": "admin", "role": "admin", "exp": <unix timestamp> }`.

All subsequent requests must include:
```
Authorization: Bearer <token>
```

---

#### `POST /api/auth/change-password`
No authentication required — TOTP code proves identity.

**Request:**
```json
{
  "username":     "operator1",
  "totp_code":    "123456",
  "new_password": "newpass99"
}
```

**Response `200`:** `{ "ok": true, "data": null }`  
**Response `200` (bad code):** `{ "ok": false, "error": "Invalid or expired TOTP code" }`

---

### 4.2 Agents

> All require `Authorization: Bearer <token>`.

#### `GET /api/agents`
Returns all agents from PostgreSQL (already synced from C&C).

**Response:**
```json
{
  "ok": true,
  "data": [{
    "uid":        "ID-A0042",
    "name":       "Alpha Node",
    "status":     "active",
    "last_seen":  "2024-01-01T12:00:00.123456Z",
    "created_at": "2024-01-01T10:00:00.000000Z",
    "lat":        "55.751244",
    "lon":        "37.618423",
    "os":         "linux",
    "hostname":   "kali-vm",
    "last_ip":    "172.20.0.5"
  }]
}
```

#### `POST /api/agents`
Requires role: `admin` or `read_write`.

**Request:**
```json
{
  "uid":  "ID-A0042",
  "name": "Alpha Node",
  "lat":  "55.751244",
  "lon":  "37,618423"
}
```

Notes:
- `uid` must match `^ID-A\d{2,6}$`
- Commas in lat/lon are auto-converted to dots server-side
- `lat` range: −90 to +90; `lon` range: −180 to +180
- `lat`/`lon` are optional; if provided, sets `geo_locked = true`

**Response `201`:** The created agent row.

#### `PUT /api/agents/:uid`
Requires role: `admin` or `read_write`.

**Request (all fields optional):**
```json
{
  "name": "Renamed Node",
  "lat":  "48.858844",
  "lon":  "2.294351"
}
```

If `lat` or `lon` is provided, `geo_locked` is set to `true` and the sync task will no longer update geo for this agent from heartbeat data.

#### `DELETE /api/agents/:uid`
Requires role: `admin`.

---

### 4.3 Users

#### `GET /api/users`
Requires role: `admin`.

**Response:**
```json
{
  "ok": true,
  "data": [{
    "id":         "550e8400-e29b-41d4-a716-446655440000",
    "username":   "operator1",
    "role":       "read_write",
    "created_at": "2024-01-01T09:00:00.000000Z"
  }]
}
```

#### `POST /api/users`
Requires role: `admin`.

**Request:**
```json
{
  "username": "operator1",
  "password": "securepass",
  "role":     "read_write"
}
```

Role values: `admin`, `read_write`, `read_only`.  
Username: 3–64 chars, regex `^[a-zA-Z0-9_\-\.]+$`.  
Password: minimum 8 characters.

#### `DELETE /api/users/:id`
Requires role: `admin`. Cannot delete own account.

#### `POST /api/users/:id/totp/setup`
Requires role: `admin`.

Generates a new TOTP secret for the user, stores it in `totp_secret`, and returns the `otpauth://` URI for QR scanning.

**Response:**
```json
{
  "ok": true,
  "data": {
    "otpauth_url":   "otpauth://totp/CYNOSURE:operator1?secret=BASE32SECRET&issuer=CYNOSURE",
    "secret_base32": "JBSWY3DPEHPK3PXP"
  }
}
```

---

### 4.4 Audit Logs

#### `GET /api/logs`
Requires any valid token.

**Query parameters (all optional):**

| Param | Type | Description |
|---|---|---|
| `username` | string | Filter by operator username |
| `action` | string | Filter by action type |
| `limit` | integer | Max rows (default 200, max 500) |
| `offset` | integer | Pagination offset |

**Action values:** `CREATE_AGENT`, `UPDATE_AGENT`, `DELETE_AGENT`, `CREATE_USER`, `DELETE_USER`

**Response:**
```json
{
  "ok": true,
  "data": [{
    "id":        "550e8400-...",
    "timestamp": "2024-01-01T12:00:00.123456Z",
    "user":      "admin",
    "action":    "CREATE_AGENT",
    "target":    "ID-A0042",
    "details":   "Alpha Node",
    "hmac":      "a3f2c1..."
  }]
}
```

#### `GET /api/logs/verify`
Requires any valid token.

Re-computes HMAC-SHA256 for every log entry and compares to the stored value.

**Response:**
```json
{
  "ok": true,
  "data": {
    "total":    42,
    "ok":       42,
    "tampered": []
  }
}
```

If `tampered` is non-empty, it contains the UUIDs of the affected rows.

---

### 4.5 C&C Internal Endpoints

These are called by agents and by the Client sync task. Operators do not call them directly.

#### `POST /api/heartbeat` (C&C :9000)

**Request:**
```json
{
  "uid":      "ID-A0042",
  "geo":      { "lat": "55.751244", "lon": "37.618423" },
  "os":       "linux",
  "hostname": "kali-vm"
}
```

**Response:**
```json
{ "ok": true, "data": { "uid": "ID-A0042" } }
```

The C&C also captures the TCP source IP from `ConnectInfo<SocketAddr>` and stores it as `last_ip`.

#### `GET /api/sync` (C&C :9000)
Called by Client every 15 seconds. Returns all agent records with fresh status computation.

---

## 5. Agent Protocol

### 5.1 UID Generation and Persistence

```
First run:
  1. Generate UUID v4
  2. seed = bytes[0..3] as u32
  3. uid  = format!("ID-A{:04}", seed % 10000)
  4. Write uid to .cynosure_agent_uid (beside binary)
  5. Use uid

Subsequent runs:
  1. Read .cynosure_agent_uid
  2. Use uid (no generation)
```

The UID is **binary-instance scoped**, not machine or user scoped.

### 5.2 Geo Generation (Lab Mode)

```
seed  = FNV-1a hash of uid bytes
lat   = (seed % 14000) / 100.0 - 70.0      → range [-70.0, +70.0]
lon   = (seed * 2654435761 % 35980) / 100.0 - 179.9  → range [-179.9, +179.9]
```

This produces a stable, varied coordinate per UID. Replace with real GPS source for production.

### 5.3 Heartbeat Timing

| Parameter | Value |
|---|---|
| Interval | 10 seconds |
| Offline threshold (C&C) | 30 seconds |
| Sync interval (Client←C&C) | 15 seconds |

An agent can miss up to 2 heartbeats before being marked offline.

---

## 6. Security Model

### 6.1 Authentication

**Login:** `POST /api/auth/login` returns a HS256 JWT signed with `JWT_SECRET`.

**JWT payload:**
```json
{ "sub": "admin", "role": "admin", "exp": 1704153600 }
```

**Token validation** (middleware `require_auth`):
1. Extract `Authorization: Bearer <token>` header
2. Decode and verify signature with `JWT_SECRET`
3. Check `exp` timestamp
4. Inject `Claims` into request extensions
5. Return `401` if any step fails

**Role enforcement** is always server-side. The frontend hides UI elements based on role, but every endpoint independently checks `claims.role`.

### 6.2 Role Matrix

| Operation | read_only | read_write | admin |
|---|:---:|:---:|:---:|
| View agents / logs | ✅ | ✅ | ✅ |
| Add / rename agents | ❌ | ✅ | ✅ |
| Delete agents | ❌ | ❌ | ✅ |
| View users | ❌ | ❌ | ✅ |
| Add users | ❌ | ❌ | ✅ |
| Delete users | ❌ | ❌ | ✅ |
| Setup TOTP | ❌ | ❌ | ✅ |

### 6.3 SQL Injection Prevention

**Layer 1 — Parameterized queries everywhere:**
```rust
// All queries use $1, $2 ... placeholders — user input never touches the SQL string
sqlx::query("SELECT password_hash, role FROM users WHERE username = $1")
    .bind(&body.username)
    .fetch_optional(&state.db)
    .await
```

**Layer 2 — Input validation before DB:**
- Usernames: `^[a-zA-Z0-9_\-\.]+$` (regex in `routes/users.rs`)
- Agent UIDs: `^ID-A\d{2,6}$`
- Passwords: length 8–128 checked before hashing
- Coordinates: parsed as `f64`, range-checked, reformatted

**Testing SQL injection resistance:**
```bash
# Classic injection — should return "Invalid credentials"
curl -s -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin'\''--","password":"x"}' | jq .ok

# Boolean-based injection
curl -s -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"x'\'' OR '\''1'\''='\''1","password":""}' | jq .ok

# UNION injection
curl -s -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"x'\'' UNION SELECT password_hash,role FROM users--","password":""}' | jq .ok

# All three should return: false
```

### 6.4 Password Storage

Passwords are hashed with **Argon2id** (memory-hard):
```rust
Argon2::default().hash_password(password.as_bytes(), &salt)
// Produces: $argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>
```

Verification uses constant-time comparison via the `argon2` crate's `verify_password`.

### 6.5 Audit Log Integrity (HMAC-SHA256)

Every write operation is logged. Each log entry is protected by a per-row HMAC:

```
message = "{timestamp}|{username}|{action}|{target}|{details}"
hmac    = HMAC-SHA256(message, HMAC_KEY)
```

Timestamp is formatted with microsecond precision (`SecondsFormat::Micros`) to match PostgreSQL's `TIMESTAMPTZ` storage precision exactly — preventing false tampering reports caused by nanosecond truncation.

**On startup**, `resign_audit_logs()` re-signs any legacy rows that were signed with a different timestamp format, making upgrades safe.

**Verification endpoint** `GET /api/logs/verify` recomputes all HMACs and returns the list of any rows whose stored HMAC doesn't match.

**Testing tampering detection:**
```bash
# 1. Perform any admin action (creates a log entry)
# 2. Connect to PostgreSQL and corrupt a row:
psql -U postgres cynosure -c \
  "UPDATE audit_logs SET details = 'tampered' WHERE id = (SELECT id FROM audit_logs LIMIT 1);"
# 3. Call verify:
curl -s http://localhost:8080/api/logs/verify \
  -H "Authorization: Bearer <token>" | jq .data
# → { "total": N, "ok": N-1, "tampered": ["<uuid>"] }
```

### 6.6 TOTP Password Change

Algorithm: **TOTP-SHA1, 6 digits, 30-second window** (RFC 6238).

```
Setup  (admin):  generate random 160-bit secret → store base32 in users.totp_secret
                 return otpauth:// URI → operator scans with authenticator app

Change password: client sends {username, totp_code, new_password}
                 server: load totp_secret, construct TOTP, call check_current()
                 check_current() accepts current window ±1 (30s drift tolerance)
                 if valid → hash new_password with Argon2id → update users table
```

The `totp-rs` crate handles secret generation, URI construction, and time-window verification.

---

## 7. Frontend Architecture

### 7.1 Build Pipeline

```
Rust source (frontend/src/)
        │
        ▼  rustc + wasm-bindgen
frontend_bg.wasm + frontend.js (glue, tiny)
        │
        ▼  trunk
dist/
  ├── index.html          (inlined style.css)
  ├── frontend_bg.wasm    (compressed Rust binary)
  └── frontend.js         (minimal WASM loader, auto-generated)
```

`data-wasm-opt="0"` in `index.html` disables wasm-opt post-processing (its bundled version doesn't support `memory.copy` from modern rustc). The WASM is still optimised by rustc's own `opt-level = "z"`.

### 7.2 Reactive Model (Leptos 0.6 CSR)

Leptos uses **fine-grained reactivity** — no virtual DOM diffing.

```
RwSignal<T>   → readable + writable reactive cell, Copy
ReadSignal<T> → read-only view of a signal
create_effect → runs a side-effect whenever its signals change
spawn_local   → runs an async block on the WASM event loop
store_value   → non-reactive Copy wrapper for non-Copy values (used for callbacks)
```

**Callback pattern** used throughout (required by Leptos's Fn bounds):
```rust
// Non-Copy callbacks wrapped in store_value → becomes Copy
let on_close = store_value(on_close);

// Multiple closures can independently capture a StoredValue
on:click=move |_| on_close.with_value(|f| f())  // button 1
on:click=move |_| on_close.with_value(|f| f())  // button 2 — no E0382!
```

**All-signals free-function pattern** (avoids FnOnce on multi-handler closures):
```rust
// RwSignal<T> is Copy — free functions take them as parameters
fn run_login(username: RwSignal<String>, password: RwSignal<String>, ...) { ... }

// Both handlers independently call the function — no closure sharing needed
on:click=move |_| run_login(username, password, error, loading, auth)
on:keydown=move |ev| { if ev.key()=="Enter" { run_login(username, password, error, loading, auth) } }
```

### 7.3 CYNOSURE Logo Generation

`src/logo.rs` generates the vinyl-record SVG purely from arithmetic:

```
Outer circle (r=46%)  ← black fill
  9 horizontal white stripes, clipped to outer circle
  Inner disc (r=21%)  ← blacks out stripe centres
    Inner ring outline (stroke only)
    Horizontal groove  ← black rect across centre
    Centre hole (r=10%) ← black
    Centre spindle (r=4%) ← white dot
Outer ring stroke
```

Color values (`#000`, `#fff`) are stored in `let` variables before `format!` calls, never inline in format templates (Rust's `format!` treats `#` as a format specifier prefix).

### 7.4 QR Code Generation

`src/components/users.rs` uses the `qrcode` crate (pure Rust, WASM-compatible) to render TOTP setup QR codes:

```rust
let code = QrCode::with_error_correction_level(data, EcLevel::M)?;
// Iterate module matrix → emit <rect> elements for dark cells
// Result: inline SVG string → injected via Leptos inner_html prop
```

No external QR service, no canvas, no JavaScript.

---

## 8. Configuration Reference

All configuration is via environment variables. A `.env` file is supported (via `dotenvy`).

### Client

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | `postgres://postgres:postgres@localhost:5432/cynosure` | PostgreSQL connection string |
| `CLIENT_PORT` | `8080` | HTTP listen port |
| `JWT_SECRET` | `cynosure-secret-change-in-prod` | HS256 JWT signing key — **change this** |
| `HMAC_KEY` | `cynosure-hmac-key-change-in-prod` | Audit log HMAC key — **change this** |
| `CNC_URL` | `http://localhost:9000` | C&C base URL for sync |

### C&C

| Variable | Default | Description |
|---|---|---|
| `MONGO_URL` | `mongodb://localhost:27017` | MongoDB connection string |
| `CNC_PORT` | `9000` | HTTP listen port |

### Agent

| Variable | Set by | Description |
|---|---|---|
| `CNC_URL` | `env!()` at compile time | C&C URL baked into binary at build |

To change the C&C URL for the agent, rebuild with the env var set:
```bash
CNC_URL=http://192.168.1.100:9000 cargo build --release --package agent
```

---

## 9. Deployment

### 9.1 Docker (Recommended)

```bash
cp .env.example .env
# Edit JWT_SECRET and HMAC_KEY in .env

docker compose up --build
```

**Build order inside Docker:**
1. `Dockerfile.cnc` — builds C&C binary (Rust native)
2. `Dockerfile.agent` — builds Agent binary (Rust native, size-optimised)
3. `Dockerfile.client` (two stages):
   - **Stage 1 `wasm-builder`:** installs `trunk`, compiles frontend to WASM
   - **Stage 2 `backend-builder`:** compiles Axum backend
   - **Stage 3 runtime:** copies binary + `frontend/dist/` into `debian:bookworm-slim`

**Runtime images:** All use `debian:bookworm-slim` + `ca-certificates`. No Rust toolchain in production image.

**Memory during build:** The WASM compilation (Leptos + many crates) is the bottleneck.  
Set `CARGO_BUILD_JOBS=2` and `RUSTFLAGS="-C codegen-units=1"` (already in Dockerfile.client) to limit peak RAM. On a 16 GB VM allocate at least 10 GB to Docker.

### 9.2 Running Multiple Agents

```bash
# Agent 1
mkdir /opt/agent1 && cp target/release/agent /opt/agent1/
cd /opt/agent1 && ./agent   # creates /opt/agent1/.cynosure_agent_uid

# Agent 2 (different directory = different UID file = different UID)
mkdir /opt/agent2 && cp target/release/agent /opt/agent2/
cd /opt/agent2 && ./agent
```

Or via Docker: scale the agent service:
```bash
docker compose up --scale agent=3
```

Each container gets its own UID because the UID file is in `/data/` inside the container.

### 9.3 Production Hardening Checklist

- [ ] Change `JWT_SECRET` (min 32 random chars)
- [ ] Change `HMAC_KEY` (min 32 random chars)
- [ ] Change default `admin` password immediately after first login
- [ ] Put Client behind a reverse proxy (nginx/caddy) with TLS
- [ ] Restrict C&C port (9000) to agent network only — not public
- [ ] Set up TOTP for all admin accounts
- [ ] Enable PostgreSQL authentication (not trust mode)
- [ ] Set MongoDB auth if exposed beyond localhost

---

## 10. Development Guide

### 10.1 Prerequisites

```bash
# Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# WASM target
rustup target add wasm32-unknown-unknown

# Trunk (frontend build tool)
cargo install trunk --locked

# Databases
# PostgreSQL 14+ and MongoDB 6+
```

### 10.2 Local Development

**Terminal 1 — C&C:**
```bash
MONGO_URL=mongodb://localhost:27017 CNC_PORT=9000 \
  cargo run --package cnc
```

**Terminal 2 — Client backend:**
```bash
DATABASE_URL=postgres://postgres@localhost/cynosure \
CLIENT_PORT=8080 \
CNC_URL=http://localhost:9000 \
JWT_SECRET=dev-secret-minimum-32-chars-pad!! \
HMAC_KEY=dev-hmac-key-min-32-chars-padding \
  cargo run --package client
```

**Terminal 3 — Frontend (hot reload):**
```bash
cd frontend
trunk serve --port 3000 --proxy-backend=http://localhost:8080
# Open http://localhost:3000
# Trunk rebuilds WASM on every Rust source change (~5-30s)
```

**Terminal 4 — Agent(s):**
```bash
CNC_URL=http://localhost:9000 cargo run --package agent
```

### 10.3 Makefile Targets

```bash
make setup          # Install wasm32 target + trunk (one-time)
make dev-cnc        # Run C&C locally
make dev-client     # Run Client locally
make dev-frontend   # Trunk dev server on :3000
make agent          # Run one agent
make build          # Full release build (WASM + all binaries)
make check          # cargo check for all crates (fast, no link)
make docker         # docker compose up --build
make docker-down    # docker compose down -v
make clean          # cargo clean + rm frontend/dist
```

### 10.4 Adding a New Agent Field

1. **`common/src/lib.rs`** — add field to `Heartbeat` and `AgentRecord` (optional `Option<T>` recommended for WASM compat)
2. **`agent/src/main.rs`** — detect and populate the field; pass to `send_heartbeat`
3. **`cnc/src/routes.rs`** — extract from payload; add to MongoDB `$set` update doc
4. **`client/src/db.rs`** — `ALTER TABLE agents ADD COLUMN IF NOT EXISTS ...`
5. **`client/src/sync.rs`** — include in upsert query
6. **`client/src/routes/agents.rs`** — include in `SELECT` and tuple mapping; add to `AgentRow`
7. **`frontend/src/types.rs`** — add to `AgentRow` struct
8. **`frontend/src/components/agents.rs`** — display in table column
9. **`frontend/src/components/dashboard.rs`** — display on agent card

### 10.5 Workspace Structure

```
cynosure/
├── Cargo.toml          Workspace manifest (members: common, client, cnc, agent, frontend)
├── Cargo.lock          Locked dependency versions
├── common/             Shared types (both native and WASM must compile this)
│   └── src/lib.rs
├── agent/
│   ├── build.rs        Injects CNC_URL at compile time
│   └── src/main.rs
├── cnc/
│   └── src/{main,db,routes}.rs
├── client/
│   └── src/{main,auth,db,sync}.rs
│       routes/{mod,auth,agents,users,logs,totp}.rs
├── frontend/
│   ├── Cargo.toml      [lib] crate-type = ["cdylib","rlib"]
│   ├── Trunk.toml
│   ├── index.html      data-wasm-opt="0" data-target-name="frontend"
│   ├── style.css
│   └── src/
│       ├── lib.rs      #[wasm_bindgen(start)] entry point
│       ├── api.rs
│       ├── logo.rs
│       ├── state.rs
│       ├── types.rs
│       └── components/{mod,auth,nav,dashboard,agents,users,logs}.rs
├── docker-compose.yml
├── Dockerfile.{client,cnc,agent}
├── Makefile
├── README.md           Quick-start guide
└── DOCS.md             This file
```

---

## 11. Troubleshooting

### Build Issues

| Symptom | Cause | Fix |
|---|---|---|
| `can't find library 'frontend'` | Dockerfile stubs `main.rs` for a `[lib]` crate | All Dockerfiles stub `frontend/src/lib.rs`, not `main.rs` — check Dockerfile |
| `found more than one target artifact` | Both `[lib]` and `[[bin]]` detected | Ensure `frontend/src/main.rs` does not exist; only `src/lib.rs` |
| `wasm-opt: memory.copy requires bulk-memory` | Bundled wasm-opt too old | `data-wasm-opt="0"` in `index.html` disables it |
| `uuid: specify a source of randomness` | `uuid` with `v4` in WASM context | `uuid` must not be in `common/` — only in native crates |
| `E0382: use of moved value` | Non-Copy callback moved into two closures | Wrap with `store_value(cb)` → `StoredValue` is `Copy` |
| `E0525: FnOnce not Fn` | Closure moves a captured value | Use `store_value` or free functions with `RwSignal` (Copy) params |
| `#` in format! template | `format!` treats `#` as format specifier | Store color strings (`"#fff"`) in variables before `format!` |

### Runtime Issues

| Symptom | Cause | Fix |
|---|---|---|
| Black screen after login | `overflow:hidden` on `body`/`#root` clips WASM content | Remove `overflow:hidden` from `html`/`body`; use `flex:1` on shell div |
| Content one page below | Two stacked `min-height:100vh` | `#root` gets `min-height:100vh`; app shell div gets `flex:1` (no own min-height) |
| Logs always show "tampered" | Nanosecond vs microsecond timestamp mismatch | Use `to_rfc3339_opts(SecondsFormat::Micros, true)` in both write and verify |
| Geo reverts after sync | Sync overwrites manual operator geo | `geo_locked = true` set by update endpoint; sync respects it |
| Docker OOM / black screen | WASM compilation uses 10–14 GB RAM | `CARGO_BUILD_JOBS=2`, `RUSTFLAGS="-C codegen-units=1"` in Dockerfile |
| Docker can't pull images | DNS/network timeout to docker.io | Check `/etc/docker/daemon.json` for DNS: `{"dns":["8.8.8.8","8.8.4.4"]}` |
| Agent uid collision | Two agents in same directory | Each agent binary must be in its own directory |
| TOTP "invalid code" | Clock drift > 60s | Sync system clock; `check_current()` allows ±1 window (60s tolerance) |
| `active rustc` version mismatch | Dockerfile pins old Rust | All Dockerfiles use `FROM rust:latest` |

### Log Action Reference

| Action | Trigger | Target | Details |
|---|---|---|---|
| `CREATE_AGENT` | Add agent via UI | uid | display name |
| `UPDATE_AGENT` | Edit agent via UI | uid | changed fields |
| `DELETE_AGENT` | Remove agent via UI | uid | — |
| `CREATE_USER` | Add operator | username | role |
| `DELETE_USER` | Revoke operator | user UUID | — |

---

*Generated for CYNOSURE v1.0.0 — Lab use only*
