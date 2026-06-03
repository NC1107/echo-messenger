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

## Deferred audit findings (not yet issues)

These came from the 2026-06-03 deep codebase audit. They are not open GitHub issues yet because each needs a focused owner, rollout decision, or platform-specific test surface before it is actionable.

### 2026-06-03 — PM onboarding surface map is missing
- **Issue:** The product now spans auth/onboarding, account switching, contacts, DMs, groups, invites, saved messages, threads, search, settings, admin, media, push, voice, canvas, desktop shell features, and self-hosting. The repo has strong local docs, but no single PM-readable map that links each user-visible surface to its route/screen, backend endpoint, platform support, test coverage, maturity state, and known deferred gaps.
- **Why deferred:** This is product/technical documentation work, not a code defect. The ingredients already exist in `app_router.dart`, `routes/mod.rs`, `tests/e2e/audit_surfaces.ts`, and the roadmap docs, but stitching them together needs owner time and regular maintenance.
- **Pickup trigger:** Next PM/contributor onboarding, roadmap planning session, or GA readiness review. Use the Playwright surface registry and server route table as the seed, then add maturity labels such as shipped, beta, manual-only, platform-limited, and deferred.

### 2026-06-03 — Visual audit registry has manual holes
- **Issue:** `tests/e2e/audit_surfaces.ts` is a good screen catalogue, but 29 surfaces are explicitly skipped or manual-only: reset-token flow, safety number via peer route, reactions/hover/pin/media states, invite join links, member views, every voice/canvas visual state that requires LiveKit, profile/QR sheets, generic transient modals, and admin. These omissions are visible in source, but not promoted into a planning/readiness artifact.
- **Why deferred:** Most skips are legitimate automation limits rather than forgotten tests. Making them reliable requires seeded media, second-session login flows, LiveKit-in-CI, admin test accounts, or a manual screenshot cadence.
- **Pickup trigger:** Pre-GA visual QA, a design-system refresh, or the next voice-lounge release. Either wire the highest-value skipped states into the audit project or publish a manual capture checklist generated from the same registry.

### 2026-06-03 — Generated share links still hard-code the Echo apex
- **Issue:** Group invite URLs and profile/QR invite links are still generated as `https://echo-messenger.us/...` in both server and client code. That works while the apex continues to route to the app, but it conflicts with the new canonical split (`web.echo-messenger.us` for web, `us-east.echo-messenger.us` for API) and breaks self-hosters who expect links to point at their own domain.
- **Why deferred:** The apex still intentionally serves the web/API union during the migration, so this is not breaking production today. The right fix needs a canonical public web origin config, server-aware invite URL generation, and a self-host story rather than swapping one hard-coded host for another.
- **Pickup trigger:** Before Phase 3 of the domain migration turns the apex into marketing, before promoting invite links as a self-host feature, or after any tester reports copied invites opening the wrong host.

### 2026-06-03 — Prod checks and public docs still center the legacy apex
- **Issue:** `prod-smoke.yml`, `prod-uptime.yml`, release environment URLs, `README.md`, and `docs/PRIVACY.md` still use `echo-messenger.us` as the primary public target, while the client default has moved to `https://us-east.echo-messenger.us` and the web target is `https://web.echo-messenger.us`. A green uptime check can miss a canonical-host regression, and new testers/self-hosters get mixed mental models.
- **Why deferred:** The legacy apex remains deliberately live during the migration, so the current checks are still useful. Turning this into a host matrix needs careful workflow changes so we do not create noisy outage issues while DNS/Traefik are still in transition.
- **Pickup trigger:** Domain migration Phase 3, public beta, or any production incident involving only one of the canonical hosts. Add separate checks for API, web, and LiveKit, and refresh README/privacy/release URLs at the same time.

### 2026-06-03 — Language picker is ahead of localization
- **Issue:** Settings exposes Spanish, French, German, Portuguese, Japanese, and Chinese options, but the app has no generated app-localization delegate or ARB catalog. The language section is honest that only English is fully translated; selecting another locale mostly changes Flutter framework strings and leaves product copy in English.
- **Why deferred:** The UI already warns testers, and full localization requires an extraction pipeline, translation files, plural/gender handling, screenshot review, and ongoing copy ownership. Shipping partial strings ad hoc would make the product feel less trustworthy.
- **Pickup trigger:** First non-English beta tester, pre-GA internationalization planning, or any marketing decision to advertise localized support. Start with one target locale and a generated localization pipeline before adding more picker options.

### 2026-06-03 — Platform capability matrix is missing
- **Issue:** Platform behavior is uneven by design: iOS push works while Android/Web push is deferred, web voice recording/PTT has gaps, iOS image clipboard is stubbed, native update support differs from web, device enumeration varies, and desktop shell features are platform-specific. The code often documents each gap locally, but there is no user-facing or PM-facing parity matrix.
- **Why deferred:** The app is still beta and platform gaps are individually documented well enough for contributors. A matrix becomes valuable when testers and release planning need to know what is expected versus broken.
- **Pickup trigger:** More than one active tester platform, app-store/TestFlight planning, or a support question caused by platform expectations. Build a matrix across Web, Linux, Windows, Android, iOS, and macOS with columns for auth, push, voice, media, clipboard, tray/windowing, updates, and known limitations.

### 2026-06-03 — E2E suite still has skipped high-value flows
- **Issue:** The E2E layer has useful smoke and maintained lanes, but current specs still carry fixme/skip coverage for group send/receive, reactions, pinning, owner/member moderation, Flutter web sidebar semantics, and two-user browser-context login. These are product-critical flows even if unit/API tests cover pieces of them.
- **Why deferred:** Several skips are due to known Flutter web/CanvasKit or multi-session automation limits, and the maintained suite already exercises a broad local flow. Stabilizing every scenario now would be a test-infrastructure project.
- **Pickup trigger:** Pre-GA, before changing group moderation/messaging behavior, or when adopting a more reliable multi-client UI harness. Prioritize one two-user group-message path, one moderation path, and the sidebar semantics regression before expanding the rest.

### 2026-06-03 — Client coverage floor is still a low ratchet
- **Issue:** Flutter CI enforces only a 35 percent line-coverage floor, lowered after a large feature batch. The test count is strong, but the global floor is too low to communicate release confidence and does not distinguish critical surfaces from low-risk UI glue.
- **Why deferred:** Raising it mechanically could block useful work without improving the highest-risk paths. The better shape is a ratchet plus targeted coverage expectations for auth, crypto/session, WebSocket, media, and message-state flows.
- **Pickup trigger:** Pre-GA or after the next large client feature batch. Raise the global floor gradually and add focused coverage checks or required tests for high-risk modules instead of chasing percentage alone.

### 2026-06-03 — Cross-site refresh cookie needs post-beta CSRF hardening
- **Issue:** Refresh cookies now use `SameSite=None` for the web/API host split. The server bounds the risk with a credentialed-origin allow-list on `/api/auth/refresh` and `/api/auth/logout`, but the domain-migration doc still calls out a double-submit cookie or per-session CSRF token as the more complete post-beta defense.
- **Why deferred:** The current exposure is narrow and already mitigated: only refresh/logout read the cookie, and non-allowed origins are rejected. Adding a token defense is worthwhile but should be done deliberately with web, mobile, and desktop clients all accounted for.
- **Pickup trigger:** Before public beta/GA, before expanding allowed web origins, or before any third-party/marketing origin serves pages under the Echo domain.

### 2026-06-03 — Threat model is split across docs instead of consolidated
- **Issue:** Crypto docs, privacy docs, domain-migration notes, link-preview SSRF hardening, push docs, voice/canvas notes, and admin metrics comments all contain pieces of the security model. There is no single threat model covering content, metadata, media URLs/tickets, link previews, push payloads, LiveKit, canvas plaintext, admin powers, self-host trust, and domain migration.
- **Why deferred:** The individual docs are more actionable for implementers right now, and the project is still changing quickly. A consolidated model would be most useful once the major protocol and domain migration decisions settle.
- **Pickup trigger:** Public beta/GA, external security review, or any significant privacy-policy update. Produce one concise model with assets, adversaries, trust boundaries, accepted risks, and follow-up issues.

### 2026-06-03 — Encrypted group edge operations remain incomplete
- **Issue:** GRP2 infrastructure is much further along, but some product operations still surface as unsupported or best-effort: editing encrypted messages returns 409 until per-device ciphertext fanout exists, and group-key rotation recovery still relies on first-writer-wins without leader election or guaranteed recovery from partial rotations.
- **Why deferred:** The app correctly refuses unsafe plaintext fallbacks, and group E2E work is already tracked in design docs. Filling these gaps needs protocol work plus user-facing failure states, not a small UI patch.
- **Pickup trigger:** Before encrypted groups are marketed as complete, before enabling encrypted groups by default, or after any group-key rotation wedging report.

### 2026-06-03 — Ops maturity needs restore drills and alert/runbook polish
- **Issue:** The repo has production uptime checks, a manual prod smoke workflow, a Prometheus metrics endpoint, and self-host backup/restore instructions. It does not yet have a scheduled restore drill, SLO/error-budget language, alert routing beyond GitHub issues, or a runbook that ties health checks, metrics, Watchtower deploys, backups, and rollback together.
- **Why deferred:** Current beta operations are single-operator and the existing checks catch basic outages. Formalizing ops process too early can become stale paperwork unless it is tied to real deployment practice.
- **Pickup trigger:** More than one operator, public beta, or the first restore/rollback incident. Start with a quarterly restore rehearsal and a short "prod incident checklist" linked from the uptime issue body.

### 2026-06-03 — Privacy/public disclosures trail platform reality
- **Issue:** `docs/PRIVACY.md` still names the apex as the central hosted server and lists FCM alongside APNs even though Android/Web push are not fully wired yet. The document is mostly accurate in spirit, but it should track the current domain layout and platform rollout precisely because it is the public privacy promise.
- **Why deferred:** Privacy copy changes should be reviewed as a product/legal posture, not casually patched during an engineering audit. The beta doc already says it evolves with the product.
- **Pickup trigger:** Any public beta announcement, domain migration Phase 3, Android/Web push work, or crash-reporting/telemetry decision.

### 2026-06-03 — WebSocket error frames are dropped client-side
- **Issue:** The server sends `ServerMessage::Error` for validation failures, rate-limit violations, canvas caps, membership failures, and persistence failures, but `ws_message_handler.dart` currently `break`s on `type == 'error'` without logging, toast feedback, optimistic rollback, or feature-specific recovery. This can make a failed send, voice action, or canvas write look like it simply did nothing.
- **Why deferred:** A generic "toast every WS error" fix would be noisy and may leak low-level validation codes. The right shape is a typed error mapping that routes message, canvas, voice, and auth errors to the owning provider with throttling and rollback semantics.
- **Pickup trigger:** First user report of an unexplained failed send/canvas/voice action, OR before flipping any stricter WebSocket validation mode in production.

### 2026-06-03 — Canvas validators still default to `log_only`
- **Issue:** `CANVAS_VALIDATION_MODE` defaults to `log_only`, so malformed canvas payloads are logged but still relayed and persisted. The validators are strong, but the safety value is unrealized until production either flips to `enforce` or has an explicit, dated soak decision.
- **Why deferred:** Enforcing too early can break older clients or self-hosters if legitimate frames are still outside the schema. The rollout needs a short production-log review plus a documented escape hatch.
- **Pickup trigger:** Two clean weeks of production canvas-validation logs, OR before broader beta/GA access to voice lounges.

### 2026-06-03 — Canvas attach buffers are unbounded during snapshot fetch
- **Issue:** `CanvasController._pendingEvents` buffers inbound canvas events while the REST snapshot is loading, but the list has no max size or drop policy. A slow fetch plus an active or malicious peer can grow memory before attach completes.
- **Why deferred:** Normal snapshot windows are short and the server already caps individual WS frame size/rate, so this needs targeted load testing rather than an emergency patch.
- **Pickup trigger:** First report of high memory/jank on lounge join, OR the next voice-lounge hardening pass. Cap to a small window (for example 256 events) with a drop-oldest policy and a debug counter.

### 2026-06-03 — Voice-lounge modules are past maintainable size
- **Issue:** `voice_lounge_screen.dart` (~1,888 lines), `canvas_provider.dart` (~1,380 lines), and `voice_canvas.dart` (~1,265 lines) remain large orchestration files. This makes lifecycle, authority, gesture, and rendering changes harder to audit against the project's SonarCloud complexity budgets.
- **Why deferred:** Recent voice-lounge work prioritized crash fixes, canvas feel, and multi-device correctness. A mechanical split now would create review churn unless paired with the next functional change.
- **Pickup trigger:** Next non-trivial voice-lounge PR, or any SonarCloud complexity finding in these files. Split along existing seams: viewport/gesture state, canvas event buffering, avatar/screen-share layers, and top-bar/dock composition.

### 2026-06-03 — Context menus are pointer-first, not keyboard-first
- **Issue:** Desktop/web context menus support pointer activation and Esc dismiss, but full keyboard navigation is still deferred. Menu rows are `GestureDetector`-based, the submenu back row and emoji buttons lack complete semantic button treatment, and arrow-key/Enter activation is not implemented.
- **Why deferred:** The current surface is usable with mouse/touch and has regression tests for opening, submenus, and Esc. Proper keyboard support needs focus order, roving selection, submenu semantics, and widget tests.
- **Pickup trigger:** Pre-GA accessibility sweep, or first keyboard/screen-reader tester using desktop/web context menus.

### 2026-06-03 — Non-Rust dependency vulnerability scanning gap
- **Issue:** Security CI covers Rust (`cargo audit`, `cargo deny`) and secrets, but it does not scan `apps/client/pubspec.lock`, the root `package-lock.json`, or `tests/e2e/package-lock.json`. Flutter, Playwright, and Node tooling advisories rely on manual review today.
- **Why deferred:** Adding OSV/npm scanning is CI policy work, not product code. It needs ignore ownership and a noise budget so transient dev-tool advisories do not block unrelated app work.
- **Pickup trigger:** Before public beta/GA, or immediately after adding a new network-facing Flutter/npm dependency.

### 2026-06-03 — Theme-token enforcement is not automated
- **Issue:** There are still many `Colors.*` / `Color(0x...)` usages outside `echo_theme.dart`. Some are legitimate media/canvas overlays, but component colors can drift because there is no lint, allowlist, or audit script separating intentional exceptions from theme violations.
- **Why deferred:** Replacing every hard-coded color mechanically risks flattening deliberate media, avatar, and canvas colors. The useful work is an allowlisted audit that targets ordinary UI components first.
- **Pickup trigger:** Next theme/high-contrast expansion, or pre-GA visual polish. Add a small grep-based audit with an allowlist for media overlays, canvas drawing colors, avatars, and test fixtures.

### 2026-06-03 — Web voice feature parity is incomplete
- **Issue:** Voice messages are explicitly unsupported in the browser, and push-to-talk is a no-op on web because `HardwareKeyboard` does not receive the needed browser key events. Web users can join voice but hit gaps around recording and PTT ergonomics.
- **Why deferred:** Browser recording/PTT needs web-specific permission, keyboard-event, and media-capture code paths rather than a small Flutter-only tweak.
- **Pickup trigger:** First web voice beta feedback, or before marketing the web app as voice-feature complete.

### 2026-06-03 — Notification and push failures lack user-visible recovery
- **Issue:** APNs token registration failures, local-notification init failures, and browser notification dispatch failures mostly end in debug logs or local debug-log entries. Users may miss notifications without a settings banner, retry affordance, or diagnostics state.
- **Why deferred:** The privacy stance intentionally avoids remote crash/telemetry by default, and iOS APNs is the only push path currently wired. User-visible recovery needs careful copy and platform-specific checks.
- **Pickup trigger:** First missed-notification tester report, or beta volume above roughly 20 active testers. Add a notification-health row in settings with last registration attempt/result and a retry action.

### 2026-06-03 — iOS image clipboard support is stubbed
- **Issue:** Image paste/copy works through desktop-specific helpers, but iOS still logs and returns null because Flutter's built-in Clipboard only handles text. Mobile media workflows therefore degrade to file picker/camera instead of rich paste/copy.
- **Why deferred:** Requires native pasteboard integration and device/simulator verification. This is platform feature work, not a cross-platform Dart-only fix.
- **Pickup trigger:** First iOS tester asks for image paste/copy, or an iOS media-polish sprint.

### 2026-06-03 — RTL locales remain blocked on layout testing
- **Issue:** The locale provider supports several LTR languages and explicitly defers RTL locales until layout testing is complete. There is no RTL test harness or screenshot/a11y sweep to prove chat, settings, context menus, and voice lounge survive `Directionality.rtl`.
- **Why deferred:** Shipping Arabic/Hebrew without layout coverage would create obvious text, icon-order, and gesture regressions. The current supported locales are all LTR except CJK, so this does not block today's picker.
- **Pickup trigger:** Any request to add an RTL locale, or pre-GA internationalization work.

## Deferred (kept open, labelled `deferred`)

These are tracked in GitHub as `deferred` issues with the open label intact, because each has a clear acceptance criterion and a foreseeable pickup window. Listed here so the ledger is the single place to see "what we're consciously not doing."

- **#681** — Server admin dashboard. Phase 1 has realtime stats and promotion, but the remaining surface is still substantial: feedback triage/status updates, admin route-level client gating, honest platform breakdowns for WS sessions, demotion/audit affordances for admin role changes, and richer operator visibility. Trigger: self-hoster volume OR operator complaint about server visibility.
- **#702** — Consolidate 33 migrations into v2 baseline. Risky pre-GA op with explicit step-by-step in the issue body. Trigger: GA cut window.
- **#769** — Mobile UI/UX gaps vs Echo Mobile.html design. 12-screen design-parity sweep. Trigger: needs to be broken into per-screen sub-issues before any of it is actionable; pickup happens when mobile becomes the primary distribution channel.
- **#1268** — Encrypt voice-lounge canvas events under GRP2 sender key. Canvas payloads are plaintext on the wire for encrypted groups; short-term mitigation is the one-time notice in `encrypted_canvas_notice.dart` (PR #1269). Pickup trigger: GRP2 message E2E shipped to prod (sender-key infrastructure doesn't exist yet). Related: `docs/voice-lounge/04-encrypted-canvas.md`; the multi-device authority architecture from #1274 is the per-user write-authority model this would build on.
- **#1277** — Canvas loading indicator during snapshot fetch. The 1–3 s `CanvasController.attach()` window is silent; drawing attempts are silently dropped while `_attachingChannelId != null`. Needs a non-blocking banner and a retry path on fetch failure. Pickup trigger: first tester report of "canvas feels broken on join" OR PR #1279 landing the banner widget.

## Conventions

- Add new entries when closing an issue you'd otherwise have left open just to remember it later.
- Each entry needs **Why deferred** and a **Pickup trigger**. If you can't name the trigger, the issue isn't really deferred — it's either ready to do or actually won't-fix.
- When the trigger fires, move the entry to a fresh GitHub issue (or re-open the original) and remove from here.
