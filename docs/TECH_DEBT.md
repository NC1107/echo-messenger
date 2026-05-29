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

### #1154, #1259, #1262 — Outage: prod health check failing (uptime false-positives)
- **Why closed:** Each filed by the scheduled uptime workflow during transient network blips. API + LiveKit returned 200/200 on manual recheck within minutes. Pattern: open → auto-closes on next green run; we close them manually to keep the open-list signal clean.
- **Pickup trigger:** Three failures in a row from the uptime workflow, OR a user-reported outage. Either is real; one-off scheduled-job 5xx is not.

### #182 — Cross-platform push notifications (Android FCM, Web Push)
- **Why deferred:** iOS APNs is wired and works. Android FCM + Web Push add two platform-integration efforts (Firebase project setup, FCM server key, web service worker, push-token routing per platform). Worth shipping eventually but not while iOS push has zero open complaints.
- **Pickup trigger:** First Android user reports missed background message OR Web Push becomes a requested feature.

### #425 — Rich text typing
- **Why closed:** Shipped in #1263 (2026-05-28). `MarkdownTextEditingController` renders bold/italic/strikethrough/inline-code inline as the user types, with delimiters dimmed to 40% opacity. Compact `Aa` toolbar + Ctrl/Cmd+B/I/E/Shift+X shortcuts.
- **Future work noted in #1263:** underline, spoiler, masked links, fenced code blocks, headers, @mention highlighting in the input. If anyone asks for one of those, open a fresh issue scoped to it.

### #450 — Chat folders and archive
- **Why deferred:** Three-feature umbrella (archive view, user-defined folders, swipe-actions on mobile list). Each is its own UX surface. The current three filter chips (All / DMs / Groups) cover the common cases. Soft-delete-via-archive is the most-asked piece and could ship alone first.
- **Pickup trigger:** Second user reports "I can't hide a chat without deleting it." Then start with archive + mute, defer custom folders until pattern is proven.

### #783 — Audit review-queue (68 medium + 22 low) from 2026-04-30 audit
- **Why deferred:** Long-tail backlog from a multi-agent audit. The big-ticket items already shipped as their own focused PRs over the last 6 weeks. Remaining items are individually small but together too much to bundle without losing signal.
- **Pickup trigger:** Pre-GA audit sweep — go back to `.claude/state/audit-project/review-queue-20260430-161802.md`, re-sample 10 items, ship the ones that still apply.

### #784 — Frontend audit re-run before GA
- **Why deferred:** Pre-GA gate, not a near-term cleanup. The 2026-04-30 multi-agent audit's frontend reviewer stalled, leaving Riverpod-lifecycle, GoRouter-redirect, Hive-schema-drift, WS-reconnect-backoff, and BuildContext-after-async-gap untested by a frontend specialist.
- **Pickup trigger:** GA cut. Re-run the frontend reviewer against current code; ship anything CRITICAL or HIGH it surfaces.

## Deferred (kept open, labelled `deferred`)

These are tracked in GitHub as `deferred` issues with the open label intact, because each has a clear acceptance criterion and a foreseeable pickup window. Listed here so the ledger is the single place to see "what we're consciously not doing."

- **#681** — Server admin dashboard. Substantial feature with a clear surface. Trigger: self-hoster volume OR operator complaint about server visibility.
- **#702** — Consolidate 33 migrations into v2 baseline. Risky pre-GA op with explicit step-by-step in the issue body. Trigger: GA cut window.
- **#769** — Mobile UI/UX gaps vs Echo Mobile.html design. 12-screen design-parity sweep. Trigger: needs to be broken into per-screen sub-issues before any of it is actionable; pickup happens when mobile becomes the primary distribution channel.
- **#1268** — Encrypt voice-lounge canvas events under GRP2 sender key. Canvas payloads are plaintext on the wire for encrypted groups; short-term mitigation is the one-time notice in `encrypted_canvas_notice.dart` (PR #1269). Pickup trigger: GRP2 message E2E shipped to prod (sender-key infrastructure doesn't exist yet). Related: `docs/voice-lounge/04-encrypted-canvas.md`; the multi-device authority architecture from #1274 is the per-user write-authority model this would build on.
- **#1277** — Canvas loading indicator during snapshot fetch. The 1–3 s `CanvasController.attach()` window is silent; drawing attempts are silently dropped while `_attachingChannelId != null`. Needs a non-blocking banner and a retry path on fetch failure. Pickup trigger: first tester report of "canvas feels broken on join" OR PR #1279 landing the banner widget.

## Conventions

- Add new entries when closing an issue you'd otherwise have left open just to remember it later.
- Each entry needs **Why deferred** and a **Pickup trigger**. If you can't name the trigger, the issue isn't really deferred — it's either ready to do or actually won't-fix.
- When the trigger fires, move the entry to a fresh GitHub issue (or re-open the original) and remove from here.
