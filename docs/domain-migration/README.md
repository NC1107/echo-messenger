# Domain layout migration

Restructuring `echo-messenger.us` from "single host serves web + API" into a federated layout:

| Host | Today | Target |
|---|---|---|
| `echo-messenger.us` | Web app + API + WS (Traefik priority routing) | Marketing site |
| `web.echo-messenger.us` | — | Flutter web build |
| `us-east.echo-messenger.us` | — | US-East server (API + WS) |
| `livekit.echo-messenger.us` | LiveKit signaling | Unchanged |
| Future: `us-west.`, `eu-west.`, `ap-south.` | — | Regional servers slotting into the same pattern |

The motivation: every regional server (and every self-host) becomes a server-shaped subdomain instead of "the one true Echo host"; the apex becomes brand surface; the web build lives on a single canonical hostname instead of doubling as the API origin.

## Why this is non-trivial

1. **Web refresh-token cookies.** Today they're `HttpOnly; Secure; SameSite=Strict` scoped to `/api/auth` on `echo-messenger.us`. Once the web build lives on `web.` and the API lives on `us-east.`, the cookies become cross-site. That means `SameSite=None; Secure` + a CSRF defence (origin check + per-session token header), because browsers reject credentialed `Strict` cookies across origins.
2. **Existing clients are pinned to the apex.** `apps/client/lib/src/providers/server_url_provider.dart` defines `defaultServerUrl = 'https://echo-messenger.us'`. Migrating the apex to a marketing site silently logs out every installed client unless we ship a flag-day client release that rewrites the saved server URL and the apex serves `301 → us-east.` for `/api/*` and `/ws`.
3. **Push tokens are server-URL-scoped.** APNs/FCM registrations on the current apex have to re-register against the new origin on next launch.
4. **Cert / DNS / Traefik routing.** Each new hostname needs a DNS record, a cert (Traefik's Cloudflare DNS challenge handles this automatically once labels are in place), and a Traefik router.

## The plan — three phases, never destructive

### Phase 1 — additive (this PR's scope)

Provision the new hostnames as **additional** Traefik hosts that serve the **same** content as the apex. Zero behaviour change for existing clients.

Concretely:
- DNS: A/AAAA records for `web.echo-messenger.us` and `us-east.echo-messenger.us` pointing at the same host as the apex.
- Traefik: extend `traefik.http.routers.echo-api.rule` and `echo-web.rule` to also match the new hostnames (use a `||` to union the Host matchers, not a new router, so priorities don't shift).
- Server: extend `CORS_ORIGINS` to allow the new web origin.
- Smoke-verify both new hostnames serve real content.

Apex keeps working. Easy rollback: drop the added Host matchers, the apex matchers stay intact.

**Status:** complete. Both new hostnames serve content live alongside the apex.

### Phase 2 — flip the client default + cookie (this PR)

Now that both hostnames work:

- Client default URL flipped to `https://us-east.echo-messenger.us` (`apps/client/lib/src/providers/server_url_provider.dart:14`).
- Refresh-token cookie relaxed from `SameSite=Strict` to `SameSite=None` (`apps/server/src/routes/auth.rs`). Required because the web build at `web.` and the API at `us-east.` are now cross-site origins; Strict cookies would be dropped on the fetch.
- No `KnownServer` migration code, no apex `301` redirects, no push-token re-registration code. This is a beta with one user (the project owner) — the database gets wiped during the rollout so every credential is fresh anyway.

The CSRF surface after relaxing SameSite is bounded: only `/api/auth/refresh` and `/api/auth/logout` read the cookie, and the credentialed-CORS allow-list prevents a malicious origin from reading the response. Worst case is a forced session rotation — annoying, not credential-stealing. A double-submit cookie or per-session CSRF token is a post-beta hardening item.

### Phase 3 — apex becomes marketing (separate effort, months later)

- Build the marketing site (Next.js static export, Astro, whatever — separate repo or `apps/marketing/`).
- Apex Traefik router flips to serve the marketing site.
- `web.echo-messenger.us` is the canonical web-app entry point; the apex `301`s to it.

## Tracking issues

- This work is tracked in #1063 (originally just the auth-screen picker, scope grew to the full migration).
- LiveKit hostname stays untouched — no migration needed there.
- Self-hosters are unaffected: they keep choosing their own apex.

## Cross-references

- Traefik config in this repo: `infra/docker/docker-compose.prod.yml`
- Host-side compose (NOT this repo): `~/docker-server/echo-messenger/docker-compose.yml` (see CLAUDE.md "Docker Production" for the gotchas)
- CORS config: `apps/server/src/routes/mod.rs` reads `CORS_ORIGINS` from env
- Server URL default: `apps/client/lib/src/providers/server_url_provider.dart`
- Server picker UI: `apps/client/lib/src/widgets/auth/server_subtitle.dart`
