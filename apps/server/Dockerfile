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
    curl \
    tini \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1000 echo \
    && useradd --uid 1000 --gid echo --shell /bin/sh echo

COPY --from=builder /app/target/release/echo-server /usr/local/bin/echo-server
# Audit H25 (#356): the original COPY pointed at apps/server/src/migrations
# which holds stale 001_/002_/003_ files unused since the 20250101000000
# baseline consolidated migration. The runtime sqlx::migrate!() macro
# embeds migrations from apps/server/migrations/ at compile time, so this
# COPY is purely defensive (operators who ever shell into the image to
# inspect schema history).  Point it at the right directory.
COPY apps/server/migrations /opt/echo/migrations

RUN mkdir -p /app/uploads/avatars

USER echo
EXPOSE 8080

# Audit H27 (#356): healthcheck so traefik / docker-compose stop routing
# to the container before tcp accepts refuse.  /api/health is a cheap
# unauthenticated endpoint that returns {"status": "ok", ...}.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS http://localhost:8080/api/health || exit 1

ENTRYPOINT ["tini", "--"]
CMD ["echo-server"]
