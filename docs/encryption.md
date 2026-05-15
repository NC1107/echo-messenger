# Encryption Protocol

Echo uses the **Signal Protocol** (X3DH + Double Ratchet) for end-to-end encrypted direct messages. The server never sees plaintext -- it stores and relays only ciphertext.

## How It Works

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

## Key Management

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

## Double Ratchet

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

## Wire Format

| Message Type | Format |
|---|---|
| Initial (V2, with OTP) | `[0xEC 0x02]` + identity_pub(32) + ephemeral_pub(32) + otp_id(4 LE) + ratchet_wire |
| Initial (V1, no OTP) | `[0xEC 0x01]` + identity_pub(32) + ephemeral_pub(32) + ratchet_wire |
| Normal | header_len(4 LE) + header(40) + nonce(12) + ciphertext + tag(16) |

All messages are base64-encoded over WebSocket. The server relays them without inspection.

## Security Properties

| Property | Mechanism |
|---|---|
| **Confidentiality** | AES-256-GCM per-message encryption |
| **Forward Secrecy** | Double Ratchet -- new key per message |
| **Break-in Recovery** | DH ratchet step on every reply |
| **Authentication** | Ed25519 signed prekey prevents MITM |
| **Integrity** | GCM authentication tag on every message |
| **Replay Protection** | Per-message counters + consumed keys |
| **Zero-Knowledge Server** | Server stores only ciphertext |

## Key Storage

| Data | Where | Notes |
|---|---|---|
| Identity keys | Platform secure storage (Keychain / Keystore / libsecret / DPAPI) | Survives app restarts |
| Session state | Platform secure storage | Full Double Ratchet state per peer |
| Decrypted messages | Hive local DB | Plaintext cache for instant display |
| Encrypted messages | Server PostgreSQL | Ciphertext only -- server cannot decrypt |
