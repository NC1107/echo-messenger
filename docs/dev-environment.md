# Dev environment (`dev.echo-messenger.us`)

Echo runs two production-like stacks:

| Stack | Domain | Image tag | Branch |
|-------|--------|-----------|--------|
| Production | `echo-messenger.us` | `:latest` (+ `:vX.Y.Z`) | `main` |
| Dev / staging | `dev.echo-messenger.us` | `:dev` (+ `dev-<sha>`) | `dev` |

Every push to `dev` rebuilds and pushes `ghcr.io/NC1107/echo-messenger/server:dev` and
`ghcr.io/NC1107/echo-messenger/web:dev` via `.github/workflows/dev-build.yml`. The
rolling `:dev` tag is what your dev-stack `watchtower` pulls. The accompanying
`dev-<short-sha>` tag is the rollback handle if `:dev` lands broken — pin to the
last-known-good SHA in the compose file, restart, then unpin once `:dev` is healed.

## Host setup

The same host can run both stacks: they share Traefik, are isolated by their
container names, networks, and Postgres database. Pick a separate data
volume for the dev Postgres so dev migrations can't corrupt production.

### Cloudflare DNS

Point `dev.echo-messenger.us` at the same host IP as `echo-messenger.us`
(A or AAAA, proxied). Traefik routes by hostname.

### Compose snippet

Drop this alongside the existing `~/docker-server/echo-messenger/docker-compose.yml`
(e.g. `~/docker-server/echo-messenger-dev/docker-compose.yml`):

```yaml
services:
  postgres-dev:
    image: postgres:17
    container_name: echo-postgres-dev
    restart: unless-stopped
    environment:
      POSTGRES_DB: echo_db_dev
      POSTGRES_USER: echo
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD_DEV}
    volumes:
      - postgres-dev-data:/var/lib/postgresql/data
    networks:
      - echo-dev-net

  server-dev:
    image: ghcr.io/nc1107/echo-messenger/server:dev
    container_name: echo-server-dev
    restart: unless-stopped
    depends_on:
      - postgres-dev
    environment:
      DATABASE_URL: postgres://echo:${POSTGRES_PASSWORD_DEV}@postgres-dev:5432/echo_db_dev
      JWT_SECRET: ${JWT_SECRET_DEV}
      RUST_LOG: echo_server=info
      CORS_ORIGINS: https://dev.echo-messenger.us
      LIVEKIT_API_KEY: ${LIVEKIT_API_KEY_DEV}
      LIVEKIT_API_SECRET: ${LIVEKIT_API_SECRET_DEV}
    labels:
      - traefik.enable=true
      - traefik.docker.network=traefik-public
      - traefik.http.routers.echo-api-dev.rule=Host(`dev.echo-messenger.us`) && (PathPrefix(`/api`) || PathPrefix(`/ws`))
      - traefik.http.routers.echo-api-dev.entrypoints=websecure
      - traefik.http.routers.echo-api-dev.tls.certresolver=cloudflare
      - traefik.http.routers.echo-api-dev.priority=100
      - traefik.http.services.echo-api-dev.loadbalancer.server.port=8080
    networks:
      - echo-dev-net
      - traefik-public

  web-dev:
    image: ghcr.io/nc1107/echo-messenger/web:dev
    container_name: echo-web-dev
    restart: unless-stopped
    # See CLAUDE.md "Prod topology" gotcha: the baked-in healthcheck
    # resolves localhost to IPv6 first, but nginx only listens on v4.
    # Override here so Traefik's docker provider doesn't filter the
    # container out for being "unhealthy".
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1/ >/dev/null"]
      interval: 30s
      timeout: 5s
      retries: 3
    labels:
      - traefik.enable=true
      - traefik.docker.network=traefik-public
      - traefik.http.routers.echo-web-dev.rule=Host(`dev.echo-messenger.us`)
      - traefik.http.routers.echo-web-dev.entrypoints=websecure
      - traefik.http.routers.echo-web-dev.tls.certresolver=cloudflare
      - traefik.http.routers.echo-web-dev.priority=1
      - traefik.http.services.echo-web-dev.loadbalancer.server.port=80
    networks:
      - traefik-public

volumes:
  postgres-dev-data:

networks:
  echo-dev-net:
  traefik-public:
    external: true
```

### Watchtower

The existing production watchtower (single instance, label-scoped) already
watches every container with the standard label. Either:

- Add `com.centurylinklabs.watchtower.enable=true` to each dev label set
  above (recommended), so the existing watchtower picks them up too, OR
- Run a second watchtower scoped to the `echo-dev-net` if you want
  different polling intervals for dev.

### Rolling back a bad `:dev`

```bash
# Find the last-good SHA from the dev-build run logs:
gh run list --workflow=dev-build.yml --branch=dev --limit=20

# Edit ~/docker-server/echo-messenger-dev/docker-compose.yml:
#   image: ghcr.io/nc1107/echo-messenger/server:dev-abc1234
# Restart:
docker compose -f ~/docker-server/echo-messenger-dev/docker-compose.yml \
  up -d server-dev web-dev

# Fix `:dev` in code, push to dev, then revert the pin once `:dev` rolls.
```

### Bootstrapping the dev database

First run only:

```bash
docker compose -f ~/docker-server/echo-messenger-dev/docker-compose.yml \
  up -d postgres-dev
# Wait ~5s for it to come up, then bring up the server — it auto-runs
# every migration in apps/server/migrations/ on startup.
docker compose -f ~/docker-server/echo-messenger-dev/docker-compose.yml \
  up -d server-dev web-dev
```

Promote yourself to admin (for `/api/admin/stats`):

```bash
docker compose -f ~/docker-server/echo-messenger-dev/docker-compose.yml \
  exec postgres-dev psql -U echo -d echo_db_dev \
  -c "UPDATE users SET is_admin = TRUE WHERE username = 'YOUR_USERNAME';"
```
