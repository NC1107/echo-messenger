# Echo UX Roadmap

This document is the team's reference for the next several months of
UX work in the Flutter client. It is the strategic complement to
`docs/style-sheet.md` (visual style) and supersedes
`research/ui_ux_audit.md` (older April 2026 audit) for direction.

It exists because Echo is at a transition point. The core UI works.
The visuals are coherent. But shipped polish alone won't move Echo from
"polished open-source Discord alternative" to "the communication tool
people emotionally prefer." Closing that gap is the work below.

---

## Vision

> **Persistent, spatial collaboration that feels alive.**

Voice lounge as the centerpiece. Chat as the surface around it. The
parts of the product that users feel emotionally are the parts where
Echo isn't competing with Slack, Discord, and Teams on saturated
territory.

The app should feel:

- **Spatial** — presence, proximity, ambient awareness, "a place" not
  "a screen."
- **Alive** — motion that communicates state, not motion that
  decorates.
- **Confident** — interactions that respond instantly; transitions that
  read as "this UI knows what it's doing."
- **Effortless** — the eye can parse hierarchy in <100ms; muscle
  memory rewards investment.

---

## Anti-goals

These are easy traps. None of them belong in this roadmap.

- **More glow / gradients / glassmorphism.** Premium ≠ decoration.
- **Out-Slacking Slack on density visuals.** Slack wins enterprise
  clarity by going clean and flat. Echo's strength is atmosphere — we
  shouldn't trade it away.
- **"Discord for developers" positioning.** That market is saturated
  and we lose by occupying it.
- **Cartoon motion.** No `Curves.bounceOut`, no elastic, no
  attention-grabbing celebration animations. Spring physics is for
  drag-release, not state tweens.
- **More features before fixing hierarchy.** The flat sidebar matters
  more than any new feature we could ship in the same time.

---

## Phase 0 — Motion language foundation

**Status:** shipped.

**Goal:** Replace scattered inline `Duration(milliseconds: N)` and
`Curves.foo` calls with a shared semantic vocabulary so future PRs can
tune the *feel* of the app without sweeping across dozens of widgets.

**Scope:**

- New `apps/client/lib/src/theme/motion_tokens.dart` exporting:
  - `MotionDurations` — `instant` / `quick` / `standard` / `expressive`
    / `gentle` / `pulse`.
  - `MotionCurves` — `entrance` / `exit` / `emphasis` /
    `expressiveBounce` / `decelerate`.
- Refresh the 8 most visible animation sites to use the tokens (voice
  speaking ring, participant tile, dock submenu, drawing tools,
  conversation presence dot, connection banner, thread panel scroll,
  identity-key banner).

**Acceptance:**

- `motion_tokens.dart` is the only place token values are defined.
- Refreshed sites compile, analyze cleanly, and exhibit no visible
  motion regression.
- Future PRs reference `MotionDurations` / `MotionCurves`; reviewers
  flag new inline `Duration(milliseconds: N)` outside `motion_tokens.dart`.

**Out of scope:**

- Sweeping every duration in the codebase. The remaining inline
  durations are picked up incrementally as their owning files are
  touched.
- Spring physics. `SpringSimulation` is right for Phase 3 voice-lounge
  drag-release, not for state tweens.

---

## Phase 0b — Motion expansion (incremental sweep)

**Status:** shipped (Top 5 of 15 candidates).

After the Phase 0 tokens landed, a follow-up sweep mapped 15 more
animation candidates ranked by ROI. The top 5 were lifted in:

- `widgets/message/message_status_icon.dart` — status progression
  (sending → sent → delivered → read) animates via `AnimatedSwitcher`
  + scale.
- `widgets/chat_input_bar/send_button.dart` — single animated
  container interpolates fill + border across mic / send / confirm
  modes; inner `AnimatedSwitcher` scales the icon between them.
- `widgets/chat_input_bar.dart` — reply preview bar mount/unmount uses
  `AnimatedSize(entrance)`.
- `widgets/message/reaction_bar.dart` — new reaction pills enter with
  a soft overshoot via `expressiveBounce`.
- `widgets/conversation_item.dart` — covered as part of Phase 1
  hover/active background animation.

**Remaining tier 2/3 candidates** (e.g., dock submenu scale, voice
settings switch flash, date/unread dividers, media picker panel)
intentionally not in this PR. They are picked up incrementally as
their owning files are touched.

---

## Phase 1 — Sidebar state hierarchy

**Status:** shipped. Mention badge ships as a *client-side-only* signal
(see "Out of scope / follow-ups" below); the rest of the deltas land in
the same PR as Phase 0b.

**Goal:** Unread / muted / mentioned / active conversations are
distinguishable in <100ms of glance, not after parsing color and font
weight.

**Why now:** The flattest part of the UI. Every user spends most of
their time looking at the sidebar. Discord's sidebar is genuinely fast
to parse; ours is uniform. Closing that gap is high-visibility,
low-risk, and unblocks every future onboarding / churn discussion.

**Scope:**

- Stronger unread weight (brighter name, accent timestamp, subtle
  background tint on the row — not just `FontWeight.w700`).
- Muted conversations visually de-emphasized (currently they're not).
  Reduced contrast on text + presence dot; muted icon affordance.
- Mention badge with count — distinct from unread count. Discord has
  this; we don't.
- Active-conversation elevation (subtle background, accent left edge
  bar, or comparable signal — no glow).
- Hover state: sharper distinction so the eye tracks position during
  rapid navigation.

**Files:**

- `apps/client/lib/src/widgets/conversation_item.dart` (724 LOC) —
  primary surface.
- Possibly `theme/echo_theme.dart` for new state colors (muted text,
  active row tint).

**Acceptance:**

- A/B screenshots: same conversation list, before vs after, screenshot
  parsing speed test (5-second glance: which conversations have
  unread? Which are muted?).
- Muted conversations read as "present but quiet" — visible, but not
  pulling attention.
- Mention badge visible at default density and at compact density
  (Phase 2 dependency).
- Tests in `test/widgets/conversation_item_test.dart` cover each state.

**Out of scope / follow-ups:**

- **Server-side mention persistence.** The shipped mention badge is
  derived client-side: when a `new_message` arrives, the WS handler
  scans the decrypted plaintext for `@<myUsername>`, `@everyone`, or
  `@here` and increments `Conversation.mentionCount` (a
  client-state-only field). `markAsRead` clears it. Multi-device sync
  of "you have mentions waiting" requires a server column + API
  change — deferred until needed.
- Full sidebar redesign (server list, channel tree).
- Nav rework (top bar, search, profile menu).
- Mobile-specific tweaks.

---

## Phase 2 — Density tier (Cozy / Normal / Compact)

**Status:** sidebar, message item, channel bar, settings rows,
reactions / hover-timestamp, and date-divider slices shipped.
Voice dock and remaining inline density follow-ups still open.

**Goal:** Power users get Discord-compact density. New users get
today's effective default (compact, matching the legacy
`MessageLayout.compact` behavior). Setting persists.

**Why now:** Density is the #1 user-power request in chat apps. Phase 1
also depends on a notion of "default density" — codifying it here lets
Phase 1 design against three target sizes from the start.

**Scope:**

- Promote `MessageLayout` (currently bubbles/compact/plain) into a
  global `UIDensity` provider (`cozy` / `normal` / `compact`) that
  scales:
  - Sidebar item height + avatar radius + padding.
  - Message item line-height + spacing.
  - Channel/group list density.
  - Settings rows.
- Persist to `SharedPreferences` (already the pattern for
  `messageLayoutProvider`).
- Settings UI: appearance section gets a Density radio group alongside
  the existing Layout one.
- Density-aware widgets pull from `context.density` (extension on
  `BuildContext`) — same shape as `context.surface`, `context.accent`.

**Files:**

- `apps/client/lib/src/providers/theme_provider.dart` — extend with
  `UIDensity`.
- `apps/client/lib/src/screens/settings/appearance_section.dart` —
  toggle UI.
- `apps/client/lib/src/widgets/conversation_item.dart` — already takes
  `MessageLayout`; promote to `UIDensity`.
- `apps/client/lib/src/theme/responsive.dart` — add density extension.

**Acceptance:**

- Three target sizes documented in `docs/style-sheet.md` once
  stabilized.
- Tested at 1280×800 (compact density should fit ≥40 visible
  conversations) and 1920×1200 (cozy reads as breathable).
- A11y: density doesn't break dynamic-type compatibility (system font
  scaling still works).
- Toggle persists across app restart.

**Shipped (sidebar slice):**

- `UIDensity` enum + `uiDensityProvider` with one-shot migration from
  `MessageLayout.compact` so existing users see no behavior change.
- Sidebar (`conversation_item.dart`, `conversation_panel.dart`)
  reads density via `conversationItemHeightFor()`; three-way size
  tables for row height (84/68/52), avatar radius (22/20/14),
  presence dot, group icon, fonts, padding, and gaps.
- Settings UI: new "Density" radio group in
  `screens/settings/appearance_section.dart` directly below the
  existing "Message layout" picker.

**Shipped (message-item slice):**

- Message body density: `RichTextContent` gained an optional
  `density: UIDensity?` param that drives a three-tier fontSize +
  lineHeight table (16/1.55, 15/1.47, 13/1.35).  `MessageItem`
  threads density through, replacing the `compact: widget.compactLayout`
  proxy.  Inter-message `topPad` (header + follow-up) and
  inline sender + timestamp font sizes now also key off density.
  Bubble inner padding intentionally unchanged for now.

**Shipped (channel bar slice):**

- Channel chip density: `ChannelBar` reads `uiDensityProvider` and
  threads the density through `_buildTextChannelChip` /
  `_buildVoiceChannelChip`, with one `_chipMetrics` helper packing
  padding / icon size / label size / border radius into a single
  record.  Cozy 14×9/16/14/22, Normal 10×6/14/12/20 (today's),
  Compact 8×4/12/11/18.

**Shipped (settings rows slice):**

- Settings row density: `CardRow` (settings list, log-out button,
  about row) became a `ConsumerWidget` that reads `uiDensityProvider`
  and packs row-height / horizontal padding / icon-badge size /
  label & trailing font size / chevron size into a `_CardRowMetrics`
  record.  Cozy 64/14/40/16/14/18, Normal 56/12/36/15/13/16
  (today's), Compact 44/10/28/13/12/14.  Tests pin each tier.

**Shipped (reactions slice):**

- Reaction-pill density: `ReactionBar` takes a `density` param and
  scales pill height / horizontal padding / corner radius / emoji
  font / count font / inner gap via `_ReactionMetrics`.  Cozy
  26/10/13/15/13/4, Normal 24/9/12/14/12/3, Compact 22/8/11/13/11/3
  (today's).  `MessageItem` threads `widget.density` into the bar.
- Hover-timestamp density: the on-hover edited-timestamp under each
  message scales 12 / 11 / 10 with cozy / normal / compact, matching
  the surrounding font ramp.
- Hover-action chip dimensions intentionally unchanged: the 44×44
  hit target is a WCAG 2.5.5 minimum and stays stable across tiers.

**Shipped (date-divider slice):**

- `DateDivider` became a `ConsumerWidget` that reads
  `uiDensityProvider` and scales vertical padding / horizontal label
  padding / font size via `_DateDividerMetrics`.  Cozy 8/12/12,
  Normal 6/10/11, Compact 4/8/11 (today's).  The 1-pixel rule colors
  stay constant across tiers so the divider weight reads identically.

**Deferred follow-ups (separate PRs):**

- Bubble inner padding scaling.
- Inter-chip spacing scaling on the channel bar.
- Voice control dock density.
- Per-screen density overrides.
- Mobile density (phones get a single density determined by viewport).

---

## Phase 3 — Voice lounge depth

The strategic phase. Each sub-phase ships independently and is gated on
the prior one feeling right.

### 3a — Ambient motion

**Status:** sub-slices 1 (speaking-ring polish + per-puck audio
radius) and 2 (presence trails) shipped. Sub-slice 3 (mesh ripple)
remains open and is gated on first introducing a vertex-mesh layer.

**Goal:** The voice lounge feels alive, not static.

**Scope:**

- ~~Speaking-ring polish~~ + ~~per-puck audio-radius rings~~ — shipped:
  each speaking participant now emits two outward-expanding rings
  on top of the existing tight ring, painted via a single
  `_AudioRadiusPainter`; opacity floor raised so the pulse stays
  visible. Reduce-motion fully gated.
  (`apps/client/lib/src/widgets/voice_speaking_ring.dart`)
- ~~Presence trails~~ — shipped: each draggable puck leaves a short
  fading wake of ghost circles on local drag and remote position
  updates. Pure-Dart `PuckTrail` helper, `Ticker`-driven repaint
  that pauses when the buffer drains, reduce-motion fully gated.
  (`apps/client/lib/src/widgets/puck_trail.dart`,
  `apps/client/lib/src/widgets/voice_canvas.dart`)
- Nearby-mesh ripple — when someone speaks, the canvas vertex mesh
  near them subtly distorts (low amplitude, no distraction).
  **Open** — depends on first introducing a vertex-mesh layer.
- Room-scale audio-radius visualization (concentric rings at
  *room* scale rather than per-puck). **Optional follow-up** if the
  per-puck version proves insufficient in dense rooms.

**Acceptance:** Gut check — "feels like a place" rather than "feels
like a screen." Nothing loud. All motion respects
`MediaQuery.disableAnimations`.

### 3b — Spatial logic

**Goal:** The room itself has structure, not just floating avatars.

**Scope:**

- Conversation circles — pucks naturally cluster when their owners are
  in the same channel / topic. Soft "gravity" without snapping.
- Room anchors — fixed regions of the canvas (shared screen, drawing
  area, current speaker spotlight). Pucks gravitate toward whatever
  they're attending to.
- Sticky regions — drag a puck near a region and it lightly snaps in.
- Speaker attraction — when someone speaks, nearby pucks subtly orient
  toward them (gaze-direction visual; not a hard zoom).
- Hover trails — cursors / pucks leave fading trails so motion is
  legible at low frame rates.

**Acceptance:** A first-time visitor can identify "who is talking to
whom" without reading text labels.

### 3c — Layer hierarchy

**Status:** speaker-driven attention shipped. Drawing-mode-driven
attention and saturation desaturation remain open as follow-ups.

**Goal:** The room guides attention automatically.

**Scope:**

- ~~Active speaker visually elevated~~ — shipped: scale boost +
  retained ring/audio-radius signal carries elevation.
- ~~Inactive users fade back — lower opacity, smaller size~~ —
  shipped: per-build `anyoneSpeaking` drives a `ParticipantAttention`
  enum (`speaking` / `faded` / `idle`) consumed by both grid tiles
  and canvas pucks via `AnimatedOpacity` + `AnimatedScale`.  Reduce-
  motion fully gated.  ~~less saturated avatar color~~ deferred —
  opacity reduction reads enough; promote later if user feedback
  asks for it.
- Shared content elevated — emergent: when participants fade, the
  screen-share window / drawing canvas naturally stand out without
  per-element work.  Direct elevation work deferred until needed.
- Current collaboration target (drawing-mode-driven attention) —
  **deferred** to a follow-up; speaker-driven covers most rooms
  today.

**Acceptance:** Screenshot of a busy room communicates the focal
points to a stranger in <2 seconds.

---

## Phase 4 — Stress-state hardening

**Goal:** Stop feeling mockup-y. Test the UI under chaos and fix what
breaks.

**Why last:** The earlier phases assume a polished baseline. This
phase deliberately stress-tests that baseline.

**Scope:**

- Notification overload — what does the sidebar look like at
  20 unread / 5 mentions / 3 muted-with-mention?
- Huge servers — group with 500 members, 50 channels.
- Thread explosions — 200-reply thread, 50 active participants.
- Bad network — 5s reconnect storm, lossy WebSocket, half-delivered
  messages.
- Weird attachments — 10 GIFs in a row, mixed video / audio /
  document grid.
- Multi-monitor — does the app behave when dragged between displays
  with different DPI?
- Absurd message density — paste a 10 000-character code block.
- Empty / first-run states — does a brand-new user with zero contacts
  see something useful, or a black void?

**Process:** A gallery of "hard cases" lives in `research/stress/` (new
folder). Each case gets a screenshot + a brief note on what's broken.
Fixes ship as small PRs against this checklist.

**Acceptance:** Each stress case passes a "wouldn't bounce a real
user" review.

---

## Cross-cutting concerns

These apply to every phase.

### Reduce motion

Every motion addition must respect `MediaQuery.of(context).disableAnimations`.
Pattern to reuse: `voice_speaking_ring.dart` checks
`MediaQuery.of(context).disableAnimations` before starting the pulse.

### Density-aware

Once Phase 2 ships `UIDensity`, every new widget should pull from
`context.density` instead of hard-coding sizes. Phase 1 widgets
(designed before Phase 2 lands) should be retro-fitted as part of
Phase 2.

### Documentation

Every stable convention lands in `docs/style-sheet.md`. Examples:

- New motion token added → motion-tokens section in style sheet.
- New state convention (mention badge, muted dim) → component spec in
  style sheet.

The roadmap is direction; the style sheet is the contract.

### Accessibility

Every state distinction must work without color alone. Mention badge
needs a number, muted needs an icon, active-conversation needs more
than a tint. Test with a color-blindness simulator at minimum.

---

## Success signals

Subjective:

- Returning users prefer Echo's sidebar to Discord's for parsing
  speed.
- Voice lounge users describe it as "a place" rather than "a feature."
- A11y audit doesn't surface motion-driven regressions.

Objective:

- A new Echo user can identify their unread conversations within 3
  seconds of opening the app (currently: tested anecdotally to be
  ~6–8 seconds).
- Voice lounge time-to-first-meaningful-interaction <5 seconds.
- Render performance: no jank on dense sidebar at 1000 conversations
  (Compact density target).

---

## How to use this roadmap

- **Picking up Phase N:** read this section + the relevant `Files`
  list, then write a per-PR plan against the `Acceptance` criteria.
- **Proposing a new phase:** open an issue with the same shape (Goal /
  Why now / Scope / Files / Acceptance / Out of scope).
- **Disagreeing with the direction:** edit the roadmap, propose the
  change, get sign-off. The roadmap is editable; only the anti-goals
  should resist amendment.

The roadmap is not a release plan. There are no dates. Phases ship
when the prior phase feels right, not when a calendar says so.
