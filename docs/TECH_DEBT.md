# Tech Debt Ledger

Living doc tracking items we've consciously decided **not** to fix right now, plus deferred audits. Each entry has: the issue, why it's deferred, the trigger that would make us pick it up.

Adding here is preferred to leaving a stale `open` issue: GitHub Issues stay actionable, this file holds the explicit "we know — not now" decisions.

## Closed as won't-fix-now

### #903 — Windows installer flagged by SmartScreen (untrusted publisher)
- **Why deferred:** Requires purchase of a code-signing certificate (EV ~$200–300/yr, standard ~$80/yr) plus the operational work of integrating signing into the release pipeline. No amount of in-app code change resolves it.
- **Pickup trigger:** Beta tester volume justifies the cert spend, OR we ship a Windows MSIX through the Microsoft Store (Store-signed binaries bypass SmartScreen reputation gating).
- **Workaround in repo:** `docs/SMARTSCREEN_WORKAROUND.md` documents the user-side "More info → Run anyway" flow.

### #1102 — Bind SonarCloud 'Sonar way' quality gate
- **Why deferred:** Zero code change — it's a SonarCloud UI setting (Project Settings → Quality Gates → bind 'Sonar way'). Tracked here as a one-line ops todo rather than a permanently-open code issue.
- **Pickup trigger:** Next time someone with SonarCloud admin on `NC1107_echo-messenger` is in the UI for any reason.

### #1117 — Targeted perf wins beyond chat-list cacheExtent
- **Why deferred:** Issue body lists 5 vague candidates (image cache web tuning, ListView keep-alives, typing fanout batching, WS event dedup, voice-grid virtualization). Each needs its own scope + measurement — bundling them under one issue produces drift, not perf. Better to revisit during a dedicated perf week with a fresh profile.
- **Pickup trigger:** User-reported perf regression OR scheduled perf week.

### #1136 — Desktop redesigns for 6 screens
- **Why deferred:** Bundles new-message / create-group / discover-groups / saved-messages / group-info / user-profile into one umbrella. Each screen is its own design+impl effort. Trying to do all six at once produces a 60+ commit PR that no reviewer can hold in their head, and the screens are independently shippable.
- **Pickup trigger:** Break out one sub-issue per screen, prioritized by the next user-reported friction. Discover-groups and new-message are the most-touched and are the natural first cuts.

### #1178 — Crash reporting (Sentry / GlitchTip)
- **Why deferred:** `docs/PRIVACY.md` currently states "No Sentry" as a deliberate stance. Wiring a remote crash sink — even opt-in — flips a privacy posture that we communicated publicly. That needs:
  1. A written privacy-doc revision agreed with the user (what we scrub, what we send, where it goes).
  2. A first-run / settings opt-in surface that's clearly default-off.
  3. A backend (self-hosted GlitchTip recommended over Sentry SaaS so user data stays on our infra).
  Doing this in a bundled "close out all issues" pass would either rush the privacy decision or ship a half-wired toggle. Both are worse than the status quo (the local `DebugLogService` ring buffer that testers can copy-paste from).
- **Pickup trigger:** Beta volume crosses ~50 testers, OR a P0 crash slips by because we couldn't reproduce locally. At that point: dedicate a session, write the privacy delta first, then wire GlitchTip.

### #1180 — Admin triage UI for `/api/admin/feedback`
- **Why deferred:** Substantial UI work (table + status filter + state-change endpoint + free-text search + user-profile link-out). Hard to justify before `/api/admin/feedback` has enough volume to need triage — today the operator can read the JSON directly. Prereq #1160 (admin auto-login on native) has shipped, so this is no longer blocked — just not the highest-leverage UI investment.
- **Pickup trigger:** Feedback submissions cross ~20 entries OR the operator complains that the JSON view is slowing them down.

### #1154 — Outage: prod health check failing
- **Why closed:** Self-resolved. API + LiveKit both returned 200 on manual recheck 2026-05-28. Uptime workflow auto-closes on next green run; closing manually now to clear the open list.

## Deferred (kept open, labelled `deferred`)

These are tracked in GitHub as `deferred` issues with the open label intact, because each has been triaged once and has a clear acceptance criterion. Listed here so the ledger is the single place to see "what we're consciously not doing."

- **#182** — Cross-platform push (Android FCM, Web Push). Large platform feature. Trigger: APNs alone is no longer enough.
- **#425** — Rich text input. `blocked` label. Trigger: design lands on whether we go markdown-preview or formatting toolbar.
- **#450** — Chat folders + archive. Substantial UX surface. Trigger: telegram-style folder ask hits again from real testers.
- **#681** — Server admin dashboard. Large feature. Trigger: self-hoster volume justifies the surface.
- **#702** — Consolidate 33 migrations into v2 baseline. Risky pre-GA op. Trigger: GA cut.
- **#769** — Mobile UI/UX gaps vs Echo Mobile.html design. Large design-parity sweep. Trigger: mobile becomes a primary distribution channel.
- **#783** — Audit review-queue (68 medium + 22 low). Long-tail backlog. Trigger: pre-GA audit sweep.
- **#784** — Frontend audit re-run before GA. Pre-GA gate. Trigger: GA cut.

## Conventions

- Add new entries when closing an issue you'd otherwise have left open just to remember it later.
- Each entry needs **Why deferred** and a **Pickup trigger**. If you can't name the trigger, the issue isn't really deferred — it's either ready to do or actually won't-fix.
- When the trigger fires, move the entry to a fresh GitHub issue (or re-open the original) and remove from here.
