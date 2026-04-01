# Self-Hosting Echo Messenger

## Prerequisites

- A Linux server (Ubuntu 22.04+ or Debian 12+ recommended)
- Docker Engine 24+ and Docker Compose v2+
- A domain name pointed at your server
- Cloudflare account (for DNS and TLS certificates)
- Traefik reverse proxy running on the server (see Traefik Setup below)

## DNS Setup with Cloudflare

1. Add your domain to Cloudflare if you have not already.
2. Create an A record pointing your domain (e.g. `echo-messenger.us`) to your server IP.
3. Set the proxy status to "DNS only" (grey cloud) initially. You can enable Cloudflare proxy later once TLS is confirmed working.
4. Create a Cloudflare API token with `Zone:DNS:Edit` permissions for use with Traefik's certificate resolver.

## Traefik Setup

If you do not already have Traefik running, create a Docker network and start Traefik:

```bash
docker network create traefik

docker run -d \
  --name traefik \
  --restart unless-stopped \
  --network traefik \
  -p 80:80 -p 443:443 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v traefik-certs:/certs \
  traefik:v3 \
    --providers.docker=true \
    --providers.docker.exposedbydefault=false \
    --entrypoints.web.address=:80 \
    --entrypoints.websecure.address=:443 \
    --entrypoints.web.http.redirections.entrypoint.to=websecure \
    --certificatesresolvers.cloudflare.acme.dnschallenge=true \
    --certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare \
    --certificatesresolvers.cloudflare.acme.email=your-email@example.com \
    --certificatesresolvers.cloudflare.acme.storage=/certs/acme.json
```

Set the `CF_DNS_API_TOKEN` environment variable on the Traefik container with your Cloudflare API token.

## Deployment

### 1. Clone the repository

```bash
git clone https://github.com/nc1107/echo-messenger.git
cd echo-messenger
```

### 2. Generate environment variables

```bash
cd infra/docker
cp .env.prod.example .env

# Generate secure secrets
DB_PASSWORD=$(openssl rand -base64 32)
JWT_SECRET=$(openssl rand -base64 64)

# Write them to .env
sed -i "s|change-me-generate-with-openssl-rand-base64-32|${DB_PASSWORD}|" .env
sed -i "s|change-me-generate-with-openssl-rand-base64-64|${JWT_SECRET}|" .env
```

Verify the values were written:

```bash
cat .env
```

### 3. Start the stack

```bash
docker compose -f docker-compose.prod.yml --env-file .env up -d
```

### 4. Verify the deployment

```bash
# Check all containers are running
docker compose -f docker-compose.prod.yml ps

# Check the health endpoint
curl https://your-domain.com/api/health
# Expected: {"status":"ok","version":"0.1.0","server":"Echo Messenger"}
```

## Backups

### Database backup

Create a script at `/opt/echo/backup.sh`:

```bash
#!/bin/bash
BACKUP_DIR=/opt/echo/backups
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

docker compose -f /path/to/docker-compose.prod.yml exec -T postgres \
  pg_dump -U echo echo_prod | gzip > "$BACKUP_DIR/echo_${TIMESTAMP}.sql.gz"

# Keep only the last 30 days of backups
find "$BACKUP_DIR" -name "echo_*.sql.gz" -mtime +30 -delete
```

Schedule it with cron:

```bash
chmod +x /opt/echo/backup.sh
crontab -e
# Add: 0 3 * * * /opt/echo/backup.sh
```

### Restore from backup

```bash
gunzip -c echo_20260331_030000.sql.gz | \
  docker compose -f docker-compose.prod.yml exec -T postgres \
  psql -U echo echo_prod
```

## Auto-Update via Watchtower

The production compose file includes Watchtower, which automatically pulls new images every 5 minutes (300 seconds). When a new image is pushed to `ghcr.io`, Watchtower will:

1. Detect the new image
2. Pull it
3. Gracefully stop the old container
4. Start a new container with the updated image
5. Remove the old image

No manual intervention is required for routine updates.

To check Watchtower logs:

```bash
docker compose -f docker-compose.prod.yml logs watchtower
```

## Manual Update

If you prefer to update manually or need to update immediately:

```bash
cd infra/docker

# Pull latest images
docker compose -f docker-compose.prod.yml pull

# Recreate containers with new images
docker compose -f docker-compose.prod.yml --env-file .env up -d

# Verify
docker compose -f docker-compose.prod.yml ps
curl https://your-domain.com/api/health
```

## Troubleshooting

### Check container logs

```bash
docker compose -f docker-compose.prod.yml logs server
docker compose -f docker-compose.prod.yml logs postgres
docker compose -f docker-compose.prod.yml logs web
```

### Database connection issues

If the server cannot connect to postgres, ensure the postgres container is healthy:

```bash
docker compose -f docker-compose.prod.yml ps postgres
```

The server container waits for postgres to be healthy before starting (via `depends_on` with `condition: service_healthy`).

### TLS certificate issues

Check Traefik logs for ACME/Let's Encrypt errors:

```bash
docker logs traefik
```

Ensure your Cloudflare API token has the correct permissions and your DNS records are properly configured.
