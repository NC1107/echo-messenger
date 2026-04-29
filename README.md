# Echo - Encrypted Messenger

A lightweight, cross-platform messaging app with end-to-end encryption. I'm not a fan of the direction discord is moving, and I don't think most people can setup Matrix, so this is my attempt at a replacement. I will be setting it up by default centralized, but there is always an option to host the server yourself.

## Downloads

Get the latest buildw from the [Releases page](https://github.com/NC1107/echo-messenger/releases).

| Platform | Download |
|----------|----------|
| Windows | [Echo-Setup-x64.exe](https://github.com/NC1107/echo-messenger/releases/latest/download/Echo-Setup-x64.exe) (installer) |
| Linux | [Echo-x86_64.AppImage](https://github.com/NC1107/echo-messenger/releases/latest/download/Echo-x86_64.AppImage) (single file) |
| Web | [echo-messenger.us](https://echo-messenger.us) or [echo-web.tar.gz](https://github.com/NC1107/echo-messenger/releases/latest/download/echo-web.tar.gz) (static files) |
| Server | [echo-server-linux-x64.tar.gz](https://github.com/NC1107/echo-messenger/releases/latest/download/echo-server-linux-x64.tar.gz) |
| Docker | `ghcr.io/nc1107/echo-messenger/server:latest` |

## Features

- **End-to-end encryption** -- Signal Protocol (X3DH + Double Ratchet).
- **1:1 and group messaging** -- Real-time via WebSocket
- **Group management** -- Public/private groups, owner/admin roles, kick members, edit group name, invite links
- **Public group discovery** -- Browse and join public groups with membership badges
- **Media sharing** -- Upload images, videos, PDFs. Inline image previews with lightbox viewer.
- **Message editing and deletion** -- Edit/delete your messages, changes propagate in real-time
- **Message reactions** -- Tap to react with emoji
- **Privacy controls** -- Toggle read receipts
- **Username DM invites** -- Share `#/u/{username}` deep links and QR codes to add contacts quickly
- **Per-message encryption indicator** -- Lock icon shows which messages were encrypted
- **Typing indicators** -- See when someone is typing
- **Conversations list** -- Last message preview, unread badges, timestamps
- **Cross-platform** -- Windows, Linux, Web, iOS, Android
- **Lightweight** -- <150MB RAM idle (vs Discord's 500MB+)

## Status

| Component | Status |
|-----------|--------|
| User auth (Argon2id + JWT) | Working |
| 1:1 messaging | Working |
| Group messaging | Working |
| E2E encryption (Signal Protocol) | Working (optional per-conversation) |
| Encryption toggle + WS sync | Working |
| Contacts system | Working |
| Media upload/download | Working |
| Message edit/delete | Working |
| Group owner management | Working |
| Public group discovery | Working |
| Privacy settings | Working |
| Typing indicators | Working |
| Message reactions | Working |
| CI/CD pipelines | Working |
| Multi-OS releases | Automated |

## Architecture

```
Flutter Client (Linux, Windows, Web)
  ├── Riverpod state management
  ├── GoRouter navigation
  ├── WebSocket real-time messaging
  └── Signal Protocol encryption (X3DH + Double Ratchet)

Rust Server (Axum + PostgreSQL)
  ├── REST API (auth, contacts, groups, messages, media, privacy)
  ├── WebSocket hub (message relay, typing, reactions, encryption sync)
  ├── JWT auth (15-min access + 7-day refresh tokens)
  ├── Argon2id password hashing
  └── 15 auto-applied SQL migrations

Deployment
  ├── Docker + Traefik reverse proxy
  ├── Watchtower auto-updates
  ├── Cloudflare CDN
  └── GitHub Actions CI/CD (lint, test, build, release)
```

## Encryption Protocol

Echo uses the **Signal Protocol** (X3DH + Double Ratchet) for end-to-end encrypted direct messages. The server never sees plaintext -- it stores and relays only ciphertext.

### How It Works

When two users message for the first time, a secure session is established using **X3DH** (Extended Triple Diffie-Hellman). Every subsequent message uses the **Double Ratchet** to derive a unique per-message key, providing forward secrecy and break-in recovery.

```mermaid
sequenceDiagram
    participant A as Alice (Sender)
    participant S as Server
    participant B as Bob (Receiver)

    Note over B,S: Bob registers his key bundle once
    B->>S: Upload PreKey Bundle<br/>(identity key, signed prekey,<br/>one-time prekeys)

    Note over A,S: Alice wants to send her first message
    A->>S: Fetch Bob's PreKey Bundle
    S-->>A: identity key + signed prekey<br/>+ one-time prekey

    Note over A: X3DH Key Agreement
    A->>A: Verify signed prekey signature (Ed25519)
    A->>A: Generate ephemeral key pair
    A->>A: Compute 3-4 DH operations
    A->>A: Derive shared secret (HKDF-SHA256)
    A->>A: Initialize Double Ratchet as sender

    Note over A: Encrypt first message
    A->>A: Derive per-message key from chain
    A->>A: AES-256-GCM encrypt with AAD

    A->>S: Send [X3DH header + ciphertext]
    S->>B: Relay [X3DH header + ciphertext]

    Note over B: Establish session from header
    B->>B: Extract Alice's identity + ephemeral keys
    B->>B: Compute matching DH operations
    B->>B: Derive same shared secret
    B->>B: Initialize Double Ratchet as receiver
    B->>B: Decrypt message (AES-256-GCM)

    Note over A,B: Session established -- subsequent messages
    A->>A: Ratchet forward, derive new message key
    A->>A: AES-256-GCM encrypt
    A->>S: Send [header + ciphertext]
    S->>B: Relay ciphertext
    B->>B: Ratchet forward, derive same key
    B->>B: Decrypt
```

### Key Management

```mermaid
flowchart TD
    subgraph First Launch
        A[Generate X25519 Identity Key] --> B[Generate Ed25519 Signing Key]
        B --> C[Generate Signed PreKey]
        C --> D[Sign PreKey with Ed25519]
        D --> E[Generate 10 One-Time PreKeys]
        E --> F[Upload Bundle to Server]
        F --> G[Store private keys in<br/>platform secure storage]
    end

    subgraph App Restart
        H[Load identity + signing + prekey<br/>from secure storage] --> I[Load persisted sessions]
        I --> J[Re-upload identity bundle<br/>to server - idempotent]
        J --> K{OTP count low?}
        K -->|Yes| L[Generate + upload<br/>new OTP batch]
        K -->|No| M[Ready]
        L --> M
    end

    subgraph Message Flow
        N[Get or create session] --> O[Derive per-message key<br/>from Double Ratchet chain]
        O --> P[AES-256-GCM encrypt<br/>with message header as AAD]
        P --> Q[Base64 encode + send via WebSocket]
    end

    G --> H

    style A fill:#2d5016,color:#fff
    style H fill:#1a3a5c,color:#fff
    style N fill:#5c1a3a,color:#fff
```

### Double Ratchet

Each message uses a **unique encryption key** derived from an evolving chain. Even if one key is compromised, past and future messages remain secure.

```mermaid
flowchart LR
    subgraph DH Ratchet
        DH1[DH Ratchet Step 1<br/>New key pair] --> DH2[DH Ratchet Step 2<br/>New key pair]
        DH2 --> DH3[DH Ratchet Step 3<br/>...]
    end

    subgraph Sending Chain
        RK1[Root Key] -->|HKDF| CK1[Chain Key 1]
        CK1 -->|HKDF| MK1[Message Key 1]
        CK1 -->|HKDF| CK2[Chain Key 2]
        CK2 -->|HKDF| MK2[Message Key 2]
        CK2 -->|HKDF| CK3[Chain Key 3]
        CK3 -->|HKDF| MK3[Message Key 3]
    end

    DH1 -.->|derives| RK1

    MK1 --> E1[AES-256-GCM<br/>Message 1]
    MK2 --> E2[AES-256-GCM<br/>Message 2]
    MK3 --> E3[AES-256-GCM<br/>Message 3]

    style MK1 fill:#8b0000,color:#fff
    style MK2 fill:#8b0000,color:#fff
    style MK3 fill:#8b0000,color:#fff
    style E1 fill:#333,color:#fff
    style E2 fill:#333,color:#fff
    style E3 fill:#333,color:#fff
```

### Wire Format

| Message Type | Format |
|---|---|
| Initial (V2, with OTP) | `[0xEC 0x02]` + identity_pub(32) + ephemeral_pub(32) + otp_id(4 LE) + ratchet_wire |
| Initial (V1, no OTP) | `[0xEC 0x01]` + identity_pub(32) + ephemeral_pub(32) + ratchet_wire |
| Normal | header_len(4 LE) + header(40) + nonce(12) + ciphertext + tag(16) |

All messages are base64-encoded over WebSocket. The server relays them without inspection.

### Security Properties

| Property | Mechanism |
|---|---|
| **Confidentiality** | AES-256-GCM per-message encryption |
| **Forward Secrecy** | Double Ratchet -- new key per message |
| **Break-in Recovery** | DH ratchet step on every reply |
| **Authentication** | Ed25519 signed prekey prevents MITM |
| **Integrity** | GCM authentication tag on every message |
| **Replay Protection** | Per-message counters + consumed keys |
| **Zero-Knowledge Server** | Server stores only ciphertext |

### Storage

| Data | Where | Notes |
|---|---|---|
| Identity keys | Platform secure storage (Keychain / Keystore / libsecret / DPAPI) | Survives app restarts |
| Session state | Platform secure storage | Full Double Ratchet state per peer |
| Decrypted messages | Hive local DB | Plaintext cache for instant display |
| Encrypted messages | Server PostgreSQL | Ciphertext only -- server cannot decrypt |

See [docs/SECURITY.md](docs/SECURITY.md) for reporting vulnerabilities.

## Quick Start

```bash
# Clone
git clone https://github.com/NC1107/echo-messenger.git
cd echo-messenger

# Start everything (DB + server + test user)
./scripts/run.sh

# Or manually:
cd infra/docker && docker compose up -d    # Start PostgreSQL
cargo run -p echo-server                    # Start server on :8080
cd apps/client && flutter run -d linux      # Start client
```

## Development

See [docs/setup.md](docs/setup.md) for full setup instructions.

### Prerequisites
- Rust (edition 2024)
- Flutter 3.41+
- Docker (for PostgreSQL)
- Node.js 20+ (for commitlint)

### Running Tests
```bash
cargo test --workspace                        # 241 Rust tests
cd apps/client && flutter test                # 55 Flutter tests
./scripts/test_e2e.sh                         # E2E integration tests
npx playwright test                           # Visual tests
```

### Lint & Format
```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets
cd apps/client && dart format --set-exit-if-changed .
cd apps/client && flutter analyze --fatal-infos
```

## License

[PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0). See [LICENSE](LICENSE).

This is a **source-available** license — anyone may use, modify, and contribute to Echo for any **non-commercial** purpose (personal, hobby, educational, non-profit, public-research, religious). Selling it, hosting it as a paid service, or using it inside a commercial entity is **not permitted** without a separate commercial license from the copyright holder.

Contributions are welcome via pull request. By submitting a contribution you agree that your changes are released under the same license.
