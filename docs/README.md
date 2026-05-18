# Echo Messenger — `docs/`

Project-level documentation, grouped by topic. Code-level docs live in source comments.

## Operating

- [setup.md](setup.md) — local development setup.
- [dev-environment.md](dev-environment.md) — IDE + tooling preferences.
- [release-process.md](release-process.md) — how a tagged release ships.
- [self-hosting.md](self-hosting.md) — running your own Echo server.
- [ci-gates.md](ci-gates.md) — what each CI job enforces.
- [ios-push-setup.md](ios-push-setup.md) — APNs + production push configuration.
- [ios-testflight-setup.md](ios-testflight-setup.md) — TestFlight distribution.
- [SMARTSCREEN_WORKAROUND.md](SMARTSCREEN_WORKAROUND.md) — Windows SmartScreen UX notes.

## Cryptography

- [encryption.md](encryption.md) — user-facing overview of the Signal Protocol implementation.
- [SECURITY.md](SECURITY.md) — vulnerability disclosure policy.
- [crypto-audit/](crypto-audit/) — **May 2026 audit** of the 1:1 crypto stack with a message-loss lens. Start with [crypto-audit/02-message-loss-surface.md](crypto-audit/02-message-loss-surface.md).
- [group-e2e-design/](group-e2e-design/) — design proposal for extending the half-wired group-key envelope infrastructure into a full group E2E protocol (GRP2). Open questions for product review live in [group-e2e-design/06-open-questions.md](group-e2e-design/06-open-questions.md).

## Product

- [ux-roadmap.md](ux-roadmap.md) — prioritised product roadmap.
- [PRIVACY.md](PRIVACY.md) — user-facing privacy policy.
- [style-sheet.md](style-sheet.md) — design tokens + UI conventions.
- [agent-memory.md](agent-memory.md) — how AI assistants on this project use memory.

## Contributing

- [CONTRIBUTING.md](CONTRIBUTING.md) — PR + commit conventions.
- [screenshots/](screenshots/) — reference screenshots for UI work.
