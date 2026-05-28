# Echo Privacy

Last updated: 2026-05-15. Echo is in beta; this doc evolves with the product.

## Scope of this document

This privacy policy covers the **centralized public server** hosted at `echo-messenger.us` and
operated by GitHub user `NC1107`. It does **not** apply to self-hosted deployments — if you run
your own Echo server, you are the operator and you control all data stored on it.
`NC1107` has no access to data on any instance other than `echo-messenger.us`.

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

## Voice-lounge canvas

Voice lounges include a shared canvas — drawings, screen-share window positions, and avatar positions are synchronized to everyone in the lounge in real time.

**Canvas content is server-readable. It is not end-to-end encrypted, even in groups where messages are.** When you draw a stroke, drag your avatar, or move a screen-share window in a voice lounge, the coordinates and stroke data pass through the server in plaintext, and persistent kinds (strokes, image references, board clears) are stored in the Echo database as plaintext JSON.

The pickup plan for closing this gap is tracked at [#1268](https://github.com/NC1107/echo-messenger/issues/1268); it requires the group-message E2E protocol (GRP2) to ship first. Until then, treat anything you draw or any window you reposition in a lounge as visible to the server operator.

The first time you enter a voice lounge in an encrypted group on a given device, the app shows a one-time popup acknowledging this gap so it's surfaced at the right moment, not just buried in this document. The popup is dismissible and does not return.

## Where the data lives

PostgreSQL on the server at `echo-messenger.us`. Access is restricted to the operator (GitHub user `NC1107`).

## Self-hosting

Echo is open-source and designed to be self-hosted. If you deploy your own instance:

- All data — accounts, messages, keys, media — lives exclusively on your server.
- You are the sole operator and data controller; `NC1107` receives nothing from your instance.
- This privacy policy does not govern your deployment. You are responsible for your own data
  handling practices and, where applicable, compliance with local privacy regulations.

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
