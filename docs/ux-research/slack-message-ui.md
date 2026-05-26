# Slack message-list UI — patterns reference

Focused notes on how Slack renders its message list on desktop/web, captured for cross-reference against our Discord-adjacent Flutter client. Sources: Slack Help Center (`slack.com/help`), Slack Design blog (`slack.design`), and the public Slack Brand Guidelines (`brand.slack.com`).

## 1. Message item layout
No bubbles. Each message is a horizontal row composed of a fixed-width left **avatar gutter** (~40 px), then a flexible column containing a one-line header (display name + timestamp) followed by the body. The body extends to a wide max-width (~700 px in Cozy) so attachments/code blocks render naturally. Hover surfaces a floating **action toolbar** anchored to the top-right of the row. Discord uses the same bubbleless model; the main divergence is Slack's tighter gutter and squared avatars.

## 2. Avatars
Slack's signature is the **rounded-square avatar** (~4 px corner radius), not a circle. Cozy uses 36 px; Compact uses 20 px. The avatar appears **only on the first message in a group**; follow-ups in the same group leave that gutter empty (or render a hover-only timestamp — see §4). Discord uses circular avatars at 40 px; the rounded square is the most immediately recognisable Slack tell.

## 3. Sender labels
The header is `**Display Name** · 10:42 AM`. Display name is bold, slightly larger than body text, with a small horizontal gap before a muted timestamp. Edited messages append an **"(edited)" pill in brand grey** (`#616061`-ish) at the end of the message body, not the header. Bots get a small "APP" pill next to the name. Discord puts "(edited)" inline too, but Slack's pill is more visually distinct as a separate small token.

## 4. Grouping rules
Consecutive messages from the same author **within ~5 minutes** group into a single visual block. Follow-up messages reuse the same left gutter alignment as the first — no indent — but **suppress the avatar and header**. On hover, the gutter of a follow-up reveals an **inline timestamp** (HH:MM, muted, right-aligned in the gutter). This is the single biggest density win versus a naïve "every message is full-chrome" layout. Discord's rule is similar (7-minute window) but it does indent slightly and shows the hover timestamp identically.

## 5. Compact vs Cozy
Two density themes (Preferences → Messages & media → Theme).
- **Cozy** (default): 36 px avatar, generous vertical padding, header above body.
- **Compact**: 20 px avatar, header **inline** with the first line of the body (single-line layout, IRC-style), reduced row padding (~50% vertical). Grouping still applies; follow-ups hide the avatar entirely. Discord ships a similar "Compact" mode but Slack's was the original.

## 6. Threads
Slack's signature pattern. Any message can spawn a **threaded reply**; replies live in a right-side pane, not inline. The parent message shows a **reply preview footer** ("3 replies · Last reply 2h ago · View thread") with stacked avatars of repliers. An optional checkbox "Also send to #channel" surfaces threaded replies back into the main timeline. Discord adopted threads later as separate sub-channels; Slack's model is lighter (no new channel, ephemeral pane). Likely beyond MVP for us but informs future surface.

## 7. Reactions
Emoji chips render **below the message body**, left-aligned to the body column (not the gutter). Each chip is `[emoji] count` with subtle border; viewer's own reactions get a coloured background. A small **"+" add-reaction control** trails the chip row. The primary react entrypoint is the **hover toolbar** (smiley icon, top-right). Discord is nearly identical.

## 8. System events and dividers
- **Date dividers**: thin horizontal line with a centred pill — "Today", "Yesterday", or "Friday, May 23".
- **"New messages" divider**: red horizontal line with "New" pill, anchored at the last-read boundary; persists until the user scrolls past or marks read.
- **Join/leave/system messages**: small, muted, no avatar — e.g. "alice joined #general". Channel-topic changes render the same way.

## 9. First message in a brand-new channel
Slack pins a generated header at the very top: **"This is the very beginning of the #channel-name channel."** with a description and a "Add people" / "Set a topic" CTA pair. It is non-removable and acts as both empty-state and channel meta. Discord shows a similar "Welcome to #channel" hero but with channel icon art.

## 10. Self vs others
Slack does **not** label your own messages "You" or right-align them. Your messages render with your own display name and avatar, on the left, identical to everyone else's. This mirrors Discord/IRC and contrasts with iMessage/WhatsApp's right-aligned self-bubbles. The visual asymmetry of self-vs-other is reserved for DMs in iMessage-style apps; chat-room apps treat all participants symmetrically.

## 11. Hover toolbar
Floats at the **top-right** of the message row on hover, slightly overlapping the row above. Default actions, left-to-right: **react** (smiley), **reply in thread** (speech bubble), **share message** (arrow), **save for later** (bookmark), **more** (overflow `…`). The overflow opens copy-link, pin, remind-me, mark-unread, edit (own messages), delete (own messages). Discord's hover toolbar lives in the same position but defaults to react / reply / forward / more — Slack's "save for later" and "share" are the differentiators.

---

### Design reasoning summary
Slack's choices optimise for **scannability of long, dense channel histories**: small avatars, aggressive grouping, no bubbles, and hover-revealed chrome keep the signal-to-noise ratio high. The rounded-square avatar is brand identity, not function. Threads sidestep the "long reply derails the channel" problem without fragmenting into sub-channels. For our app, the highest-leverage borrowings are: (a) 5-minute author grouping with hover-timestamp follow-ups, (b) Compact density theme, (c) rounded-square avatar option, (d) symmetric self-vs-other rendering.

## 12. Density / Compactness Controls
Slack exposes density as a single binary toggle, not a multi-tier picker. It lives under **Preferences → Themes → Compact** as a plain checkbox — there is no "Cozy / Normal / Compact" three-way selector. The two states are:

- **Cozy (default):** 36 px rounded-square avatar in the left gutter, the sender's display name rendered **bold on its own header line** above the body, generous ~12-14 px row padding, and a multi-line body that wraps naturally below the header. This is the layout the rest of this document describes by default.
- **Compact:** avatar shrinks to 20 px, the header (name + timestamp) collapses **inline with the body** as a single IRC-style line — conceptually identical to Discord's Compact mode — and row padding drops to ~4-6 px vertical. Follow-up messages in a 5-minute group still suppress the avatar entirely; the gutter just gets narrower to match the smaller avatar width. No indentation is introduced past the gutter.

Crucially, **both modes preserve the same 5-minute same-author grouping rule** (§4). Compact does not change *what* groups; it only changes the chrome around each group. Names also stay **bold in both modes** — neither Slack nor Discord ever de-emphasises the sender label, which is the reader's primary scan anchor.

**Translation to Echo:** Echo's existing Cozy / Normal / Compact tri-state is denser than Slack's binary, but where Slack and Discord agree, Echo should match: scale only padding and avatar size between tiers, and never touch the grouping logic, the bold-name treatment, or the gutter-alignment of follow-ups. Treat density as a chrome-only knob.

## 13. Channel Navigation (Sidebar vs Top Bar)
Slack's signature shell is a two-column **left sidebar**: a 60 px workspace-picker rail on the far left, then a ~240 px channel sidebar with collapsible sections (**Channels**, **Direct messages**, **Apps**). Channels are listed as `#channel-name` with mute/unread weight applied to the label. The whole channel sidebar can be collapsed to icon-only.

Slack has **no built-in voice channels** in the Discord sense. Voice calls live as **Huddles**, launched from inside a channel and surfaced as a floating dock pinned to the bottom of the sidebar. There is no "voice channel" as a navigable node in Slack's tree — voice is an action you take *within* a text channel, not a sibling of it.

**What in the message UI actually depends on the sidebar?** Almost nothing. List virtualization, 5-minute grouping, the hover toolbar, threading, reactions, date dividers, and the bubbleless row layout are all **sidebar-agnostic** — they're properties of the message column, not the shell around it. Two coupling points worth flagging:

- The **"New messages" red divider** (§8) is part of the message list and survives identically across sidebar-shell or top-tab-shell layouts.
- Slack's **Threads** tab is a top-level sidebar entry (not per-channel), so it *is* sidebar-coupled — but Echo has no threads at MVP, so this isn't load-bearing for the patterns Echo is borrowing now.

Echo's existing top-tab channel layout (visible in the reference screenshot: `general | lounge` tabs at the top, with voice rendered as a sibling channel rather than a Huddle dock) **does not break** any Slack message-list pattern Echo wants to borrow.

**Summary:** the channel-nav choice (sidebar vs top tabs) does **not** affect the message-list patterns Echo should borrow from Slack.
