# Echo Privacy

Last updated: 2026-05-15. Echo is in beta; this doc evolves with the product.

## What Echo stores

| Data | Where | Why |
|---|---|---|
| Account (username, hashed password via Argon2id) | Echo Postgres | Lets you log back in |
| 1:1 message ciphertext + envelope metadata | Echo Postgres | Delivery when the recipient is offline |
| Plaintext-group messages (sender, room, content) | Echo Postgres | Group rooms aren't E2E-encrypted yet |
| Avatar images | Echo server filesystem (`./uploads/avatars`) | Profile rendering |
| Contact graph (who is in your contacts) | Echo Postgres | Friend list display |
| Push notification tokens (APNs / FCM) | Echo Postgres | Phone wake-ups for new messages |
| In-memory rate-limit state derived from IP | Echo server RAM (no disk) | Spam / abuse prevention; cleared on restart |
| Device fingerprints + per-device public keys | Echo Postgres | Multi-device key routing for E2E |

## What Echo does NOT store

- **Plaintext of E2E-encrypted messages.** 1:1 messages use the Signal Protocol (X3DH + Double Ratchet) — the server only sees ciphertext + sender/recipient routing info.
- **Payment information.** Echo has no payments.
- **Third-party analytics or trackers.** No Mixpanel, no Segment, no Google Analytics, no Sentry.
- **Your private keys.** They're generated on-device and stored in your platform keystore (Keychain on iOS/macOS, Credential Manager on Android, libsecret on Linux, etc.).

## Where the data lives

PostgreSQL on the self-hosted server (`echo-messenger.us`). Access is restricted to the operator (GitHub user `NC1107`).

## Retention

- Messages live until you delete them or your account is deleted.
- Soft-deleted messages remain in the database until the disappearing-messages TTL or group cleanup hard-deletes them.
- Account deletion (Settings → About → Delete Account) purges every row referencing your user id via cascading foreign keys.

## Third parties

- **Apple Push Notification service (APNs)** for iOS push. Pushes carry encrypted content only — Apple cannot read messages.
- **Firebase Cloud Messaging (FCM)** for Android push. Same property — encrypted content only.
- **Cloudflare** terminates TLS and proxies HTTPS to the Echo server. Cloudflare can see request metadata (IP, headers, paths) but not message contents (E2E ciphertext is opaque to them).
- **LiveKit** is used for voice/video calls. Audio/video relays through the operator-controlled LiveKit instance.

## Contact

Privacy questions, removal requests, or beta-data-wipe coordination: please open an issue on the GitHub repo at <https://github.com/NC1107/echo-messenger>.

## Beta caveats

- Group messages are **not** end-to-end encrypted yet. The "Securing message" UI and the experimental encryption flag are scaffolds for the work tracked in #434 and #591.
- Account data may be reset before the public release. This is noted in the onboarding wizard's welcome banner.
