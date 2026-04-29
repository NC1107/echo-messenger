FROM rust:1.94.1-bookworm AS builder

WORKDIR /app

# Copy workspace manifests first for dependency caching
COPY Cargo.toml Cargo.lock ./
COPY core/rust-core/Cargo.toml core/rust-core/Cargo.toml
COPY apps/server/Cargo.toml apps/server/Cargo.toml

# Create dummy source files to build deps
RUN mkdir -p core/rust-core/src apps/server/src \
    && echo "pub fn lib() {}" > core/rust-core/src/lib.rs \
    && echo "fn main() {}" > apps/server/src/main.rs \
    && cargo build --release --package echo-server 2>/dev/null || true \
    && rm -rf core/rust-core/src apps/server/src

# Copy real source
COPY core/ core/
COPY apps/server/ apps/server/

# Touch to invalidate cache for source only
RUN touch core/rust-core/src/lib.rs apps/server/src/main.rs
RUN cargo build --release --package echo-server

# Runtime
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    ca-certificates \
    tini \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1000 echo \
    && useradd --uid 1000 --gid echo --shell /bin/sh echo

COPY --from=builder /app/target/release/echo-server /usr/local/bin/echo-server
COPY apps/server/src/migrations /opt/echo/migrations

RUN mkdir -p /app/uploads/avatars

USER echo
EXPOSE 8080

ENTRYPOINT ["tini", "--"]
CMD ["echo-server"]
