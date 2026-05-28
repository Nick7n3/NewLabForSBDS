FROM rust:latest AS builder
WORKDIR /build

RUN apt-get update && apt-get install -y pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock* ./
COPY common   ./common
COPY cnc      ./cnc
COPY client/Cargo.toml   ./client/Cargo.toml
COPY agent/Cargo.toml    ./agent/Cargo.toml
COPY frontend/Cargo.toml ./frontend/Cargo.toml

# Stub out crates not being built.
# frontend is a [lib] crate (cdylib) so needs src/lib.rs, not src/main.rs
RUN mkdir -p client/src agent/src frontend/src \
 && echo 'fn main(){}' > client/src/main.rs \
 && echo 'fn main(){}' > agent/src/main.rs \
 && echo 'pub fn _stub() {}' > frontend/src/lib.rs

RUN cargo build --release --package cnc

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/target/release/cnc /usr/local/bin/cnc
EXPOSE 9000
CMD ["cnc"]
