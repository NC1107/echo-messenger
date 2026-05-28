# Voice-lounge canvas interaction contract

This folder is the **decision-of-record** for how the voice-lounge canvas, its inputs, and its synchronization model behave. It exists because the implementation has acquired enough device-class assumptions, gesture-arena tradeoffs, and per-event wire formats that informal-knowledge approaches were producing avoidable regressions (see PRs #1247 through #1266 for the trail).

Every canvas-behavior PR from this point forward must:

1. Cite the relevant section of these docs in the PR description.
2. If the PR proposes a change that contradicts a documented decision, the doc gets updated **first**, in its own PR, with the new rationale.

## Contents

- **[01 — Coordinate policy](01-coordinate-policy.md)** — what coordinate space each canvas entity lives in, how those spaces are wire-encoded, and the rule for cross-device translation.
- **[02 — Input matrix](02-input-matrix.md)** — per-device-class mapping for pan, zoom, draw, select, and double-tap; gesture-arena precedence; conflict rules.
- **[03 — Multi-device per user](03-multi-device.md)** — how a user with 2+ devices in the same lounge is represented on the canvas, and what's read-only vs write.
- **[04 — Encrypted-group canvas](04-encrypted-canvas.md)** — current trust posture for canvas events in encrypted groups, the documented gap, and the path to closing it.

## Plan that this contract serves

The contract is **Phase 1 / PR A** of the canvas redesign plan in `canvas_redesign.md`. Phases 2-5 (server geometry validation, gesture + integration tests, legacy-coord sunset, perf budget) all depend on the decisions captured here.

## How decisions are recorded

Each doc follows the same shape:

- **Status quo** — what the code does today, with file:line citations.
- **Options** — the alternatives considered, each with cost + benefit.
- **Decision** — the option we picked and **why**, dated.
- **Acceptance criteria** — the testable rule any future PR must honor.
- **Open questions** — things deferred to a later decision, with their pickup trigger.
