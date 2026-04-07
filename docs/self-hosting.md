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

## TURN Server for Voice Channels

### Why you need TURN

Echo Messenger uses WebRTC for peer-to-peer voice channels. WebRTC requires both peers to discover each other's network addresses via ICE (Interactive Connectivity Establishment). The default setup uses Google's public STUN server, which works when both users have direct internet access.

However, **STUN alone fails for ~30% of users** who are behind:
- Symmetric NATs (common in corporate networks)
- Carrier-grade NAT (mobile networks)
- Strict firewalls that block UDP

A TURN server acts as a media relay — when direct P2P fails, audio traffic flows through the TURN server instead. Without it, voice channels silently fail to connect for affected users.

### How it works in Echo

The server already has a built-in ICE configuration endpoint (`GET /api/config/ice`). When TURN environment variables are set, the server automatically includes TURN credentials in the response. The client fetches this config when joining a voice channel — **no client code changes needed**.

### Option A: Hosted TURN (quickest, recommended for small deployments)

**Metered TURN** offers 25GB/month free (no credit card required), which is enough for light voice usage.

1. Sign up at [metered.ca](https://www.metered.ca/stun-turn)
2. Create an application and get your credentials
3. Add to your `.env` file:

```bash
TURN_URL=turn:your-subdomain.relay.metered.ca:443?transport=tcp
TURN_USERNAME=your-api-key
TURN_CREDENTIAL=your-api-secret
```

4. Pass the variables to the server container in `docker-compose.prod.yml`:

```yaml
server:
  environment:
    # ... existing vars ...
    TURN_URL: ${TURN_URL}
    TURN_USERNAME: ${TURN_USERNAME}
    TURN_CREDENTIAL: ${TURN_CREDENTIAL}
```

5. Restart the server:

```bash
docker compose -f docker-compose.prod.yml --env-file .env up -d server
```

6. Verify by calling the ICE config endpoint:

```bash
curl -s https://your-domain.com/api/config/ice \
  -H "Authorization: Bearer <your-token>" | jq .
```

You should see both STUN and TURN servers in the response.

**Other hosted options**: Twilio (pay-per-use, most reliable), Xirsys (5GB free), Cloudflare Calls.

### Option B: Self-hosted coturn (full control, free)

[coturn](https://github.com/coturn/coturn) is the standard open-source TURN server. It requires a server with a static public IP and open UDP ports.

#### Requirements

- A server with a **static public IP** (can be the same server as Echo, or a dedicated VPS)
- Open ports: **3478/TCP+UDP** (TURN signaling) and **49152-65535/UDP** (media relay range)
- ~64 Kbps bandwidth per active voice connection

#### Setup

1. Add coturn to your `docker-compose.prod.yml`:

```yaml
coturn:
  image: coturn/coturn:latest
  restart: unless-stopped
  network_mode: host
  volumes:
    - ./turnserver.conf:/etc/turnserver.conf:ro
  command: ["-c", "/etc/turnserver.conf"]
```

Note: coturn uses `network_mode: host` because it needs direct access to UDP ports. It cannot run behind Traefik (Traefik only proxies HTTP/TCP).

2. Create `infra/docker/turnserver.conf`:

```ini
# Basic settings
realm=echo-messenger.us
listening-port=3478

# Replace with your server's public IP
external-ip=YOUR_PUBLIC_IP

# Static credentials (use long-term credentials mechanism)
user=echo:your-secure-turn-password
lt-cred-mech

# Relay port range
min-port=49152
max-port=65535

# Security
no-multicast-peers
no-cli
fingerprint

# Logging
log-file=stdout
verbose
```

3. Add TURN environment variables to `.env`:

```bash
TURN_URL=turn:YOUR_PUBLIC_IP:3478?transport=udp
TURN_USERNAME=echo
TURN_CREDENTIAL=your-secure-turn-password
```

4. Pass them to the server container (same as Option A step 4).

5. Open firewall ports:

```bash
# UFW example
sudo ufw allow 3478/tcp
sudo ufw allow 3478/udp
sudo ufw allow 49152:65535/udp
```

6. Start the stack:

```bash
docker compose -f docker-compose.prod.yml --env-file .env up -d
```

7. Test TURN connectivity at [webrtc.github.io/samples/src/content/peerconnection/trickle-ice](https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/) using your TURN URL and credentials. You should see `relay` candidates appear.

### Verifying voice works through TURN

1. Have two users join the same voice channel
2. At least one user should be on a restricted network (or use a VPN to simulate)
3. If audio connects, TURN is working
4. Check coturn logs for relay activity:

```bash
docker compose -f docker-compose.prod.yml logs coturn
```

## Voice/Video (LiveKit)

Echo Messenger uses [LiveKit](https://github.com/livekit/livekit), an open-source SFU (Selective Forwarding Unit), for voice and video channels. LiveKit handles media routing server-side, which scales far better than P2P mesh for groups larger than 5-8 users.

### Required environment variables

Add these to your `.env` file:

```bash
LIVEKIT_API_KEY=your-api-key
LIVEKIT_API_SECRET=your-api-secret
```

### Generate keys

```bash
docker run --rm livekit/generate-keys
```

This prints a key pair you can paste directly into `.env`.

### Port requirements

LiveKit requires the following ports open on your server firewall:

| Port | Protocol | Purpose |
|------|----------|---------|
| 7880 | TCP | HTTP API |
| 7881 | TCP | WebSocket (signaling) |
| 7882 | UDP | WebRTC (ICE/DTLS) |
| 50000-50200 | UDP | RTP media relay range |

```bash
# UFW example
sudo ufw allow 7880/tcp
sudo ufw allow 7881/tcp
sudo ufw allow 7882/udp
sudo ufw allow 50000:50200/udp
```

### How it works

The Echo server exposes `POST /api/voice/token` which generates a LiveKit-compatible JWT. The client calls this endpoint before joining a voice channel, then connects directly to LiveKit using the returned token. LiveKit handles all media routing, eliminating the need for a separate TURN server for voice/video traffic.

### Verify LiveKit is running

```bash
docker compose -f docker-compose.prod.yml logs livekit
```

You should see `starting in single-node mode` in the output.

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
