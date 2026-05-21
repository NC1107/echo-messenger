# Phase 1 server-admin handoff — domain migration

**Goal:** add `web.echo-messenger.us` and `us-east.echo-messenger.us` as additional Traefik hosts serving the same content as the apex. **Zero behaviour change for end users in this phase.** It is purely additive — existing clients on `echo-messenger.us` continue to work unchanged.

**Time estimate:** 20–40 minutes including verification.

**Rollback:** drop the added Traefik Host rules, restart Traefik. Apex still works because none of its rules are removed in Phase 1.

---

## Step 1 — DNS

Add two records pointing at the same host that already serves `echo-messenger.us`:

| Type | Name | Value | Proxy / TTL |
|---|---|---|---|
| A | `web.echo-messenger.us` | (same IPv4 as apex) | Same as apex (proxy on/off identical) |
| A | `us-east.echo-messenger.us` | (same IPv4 as apex) | Same as apex |
| AAAA | `web.echo-messenger.us` | (same IPv6 as apex, if you have one) | Same as apex |
| AAAA | `us-east.echo-messenger.us` | (same IPv6 as apex, if you have one) | Same as apex |

If you proxy the apex through Cloudflare's edge, do the same for both new records. The cert resolver (Traefik's `cloudflare` resolver via DNS-01 challenge) works through Cloudflare proxy without changes — that's the whole point of DNS challenge.

Verify with `dig`:

```bash
dig +short web.echo-messenger.us
dig +short us-east.echo-messenger.us
# Both should return the same A record(s) as `echo-messenger.us`.
```

---

## Step 2 — Traefik labels on the host compose file

The host runs a compose file at `~/docker-server/echo-messenger/docker-compose.yml` (per the project's `CLAUDE.md` "Docker Production" notes). That file is **not** the same as the repo's `infra/docker/docker-compose.prod.yml`, although they're meant to track each other. Edit the host file in place.

Find the **server** (API) service. Its current labels look like this:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.echo-api.rule=Host(`echo-messenger.us`) && (PathPrefix(`/api`) || PathPrefix(`/ws`))"
  - "traefik.http.routers.echo-api.priority=100"
  - "traefik.http.routers.echo-api.tls=true"
  - "traefik.http.routers.echo-api.tls.certresolver=cloudflare"
  - "traefik.http.services.echo-api.loadbalancer.server.port=8080"
```

Change the `echo-api.rule` line to **union** the apex and the new server hostname:

```yaml
  - "traefik.http.routers.echo-api.rule=(Host(`echo-messenger.us`) || Host(`us-east.echo-messenger.us`)) && (PathPrefix(`/api`) || PathPrefix(`/ws`))"
```

Find the **web** service:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.echo-web.rule=Host(`echo-messenger.us`)"
  - "traefik.http.routers.echo-web.priority=1"
  - "traefik.http.routers.echo-web.tls=true"
  - "traefik.http.routers.echo-web.tls.certresolver=cloudflare"
  - "traefik.http.services.echo-web.loadbalancer.server.port=80"
```

Change the `echo-web.rule` line to:

```yaml
  - "traefik.http.routers.echo-web.rule=Host(`echo-messenger.us`) || Host(`web.echo-messenger.us`)"
```

**Do not** create new router names (e.g. `echo-api-use` or `echo-web-new`). Reusing the existing router names keeps the priority settings (100 for API, 1 for web) intact and avoids a class of subtle bugs where a new router with default priority intercepts requests it shouldn't.

`livekit.echo-messenger.us` stays unchanged — it's a separate service in a separate router.

---

## Step 3 — Server env: extend `CORS_ORIGINS`

Find the `.env` file the host's compose uses for the `server` service (typically `~/docker-server/echo-messenger/.env`). Locate the `CORS_ORIGINS` variable. It currently looks like:

```
CORS_ORIGINS=https://echo-messenger.us
```

Add the new web origin (comma-separated, no spaces):

```
CORS_ORIGINS=https://echo-messenger.us,https://web.echo-messenger.us
```

We **do not** add `https://us-east.echo-messenger.us` to CORS — that's the API origin, not a browser origin. Adding it would have no effect (it never appears in an `Origin` header) but would muddle intent.

If `CORS_ORIGINS` isn't set in `.env`, the server's built-in default in `apps/server/src/routes/mod.rs` is being updated in the same client release that ships these docs, so the default will include both origins. Explicit `.env` setting still wins.

---

## Step 4 — Apply

```bash
cd ~/docker-server/echo-messenger

# Recreate the affected containers so Traefik picks up the new labels
# and the server reads the new CORS_ORIGINS.
docker compose up -d --force-recreate web server

# Verify Traefik picked them up.
docker compose logs traefik 2>&1 | grep -E "(echo-api|echo-web)" | tail
```

Traefik will provision certs for the two new hostnames automatically via the existing `cloudflare` DNS-01 challenge. Cert issuance typically takes 15–60 seconds; check Traefik logs for `Server responded with a certificate`.

---

## Step 5 — Verify

From any machine (not the host):

```bash
# Web origin should serve the Flutter web build.
curl -sSI https://web.echo-messenger.us | head -1
# Expect: HTTP/2 200

# API origin should serve the API health check.
curl -sS https://us-east.echo-messenger.us/api/health
# Expect: {"status":"ok"}  (or whatever the current health body is)

# WebSocket upgrade on the API origin.
curl -sSI -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dummy" \
  https://us-east.echo-messenger.us/ws
# Expect: HTTP/2 400 or 401 (NOT 404; 404 means the route didn't match)

# Apex still works exactly as before.
curl -sSI https://echo-messenger.us | head -1
curl -sS  https://echo-messenger.us/api/health
```

Browser smoke test:

1. Open `https://web.echo-messenger.us` → Echo web app loads, login screen visible.
2. Open the in-app server picker (the "Server: ..." subtitle on the login screen), click it, paste `https://us-east.echo-messenger.us` into the custom URL field, hit Connect. The pre-flight against `/api/server-info` should succeed and switch you.
3. Log in. You should land in chat, see your conversations, and be able to send a message.
4. Open `https://echo-messenger.us` in another tab → still works, still logged in.

If any of the above fails, see "Rollback" at the bottom of this doc.

---

## Step 6 — Tell us when you're done

Reply on the tracking issue (#1063) with:

- DNS records confirmed live (`dig` output).
- `docker compose ps` showing healthy `web` and `server` containers.
- The four `curl` verification commands' output.
- Any deviations or warnings observed in `docker compose logs traefik`.

We'll then plan Phase 2 (flipping the client default + apex redirects). That's a separate handoff — it requires a client release first.

---

## Rollback

If anything misbehaves and you need to revert:

1. **Restore the original Traefik labels** in `~/docker-server/echo-messenger/docker-compose.yml`:
   ```yaml
   - "traefik.http.routers.echo-api.rule=Host(`echo-messenger.us`) && (PathPrefix(`/api`) || PathPrefix(`/ws`))"
   - "traefik.http.routers.echo-web.rule=Host(`echo-messenger.us`)"
   ```
2. (Optional) restore the original `CORS_ORIGINS` in `.env` — but leaving the extra origin in is harmless.
3. `docker compose up -d --force-recreate web server`
4. The new DNS records can stay — they'll just resolve to a host that doesn't serve their hostname, which is no worse than not having them at all.

The whole Phase 1 change is reversible in under 5 minutes from the host.

---

## What is NOT changing in Phase 1

- Clients still hit `echo-messenger.us`. No client release is required.
- Push notifications keep working. Tokens are still registered against the apex.
- LiveKit signaling at `livekit.echo-messenger.us` is untouched.
- Refresh-token cookies remain `SameSite=Strict` scoped to the apex.
- Watchtower-driven release cadence is unchanged — both `web` and `server` images still come from `:latest`.

---

## Reference — repo state matching this work

This PR (the one bundling these docs) updates the repo's reference compose file (`infra/docker/docker-compose.prod.yml`) to match the Traefik label shape above, and bumps the server's built-in `CORS_ORIGINS` default to include `https://web.echo-messenger.us`. The host's compose file is independent; you still need to edit it manually as documented above.
