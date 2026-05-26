# Discord Message UI — desktop/web research

Focused notes on how Discord's web client renders its message list, and which patterns are worth borrowing for Echo. Discord is the closest analogue to our Flutter web chat surface, so the structural choices here are a useful baseline.

## 1. Message item layout (no bubbles)

Discord renders messages as **flat rows on the channel background**, not as chat bubbles. The row has three regions: a left avatar gutter (~40px wide), the message body column, and a hover-only action toolbar that floats at the top-right of the row. The first message in a group carries the avatar plus a header line (`DisplayName · timestamp`); follow-up messages in the same group are pure body text indented into the avatar gutter's column. Reasoning: bubbles are optimised for two-party SMS-style conversations; multi-party servers need denser scanning and a clear "author header → reply body" hierarchy. Bubbles also waste horizontal space on wide desktop viewports.

## 2. Avatars

Circular, ~40px in Cozy mode, positioned flush in the left gutter. The avatar appears **only on the first message of a group**. Subsequent messages from the same author within the grouping window omit the avatar entirely; the body text starts at the same x-offset as the prior message's body, preserving the vertical column. On hover of a follow-up message, a dim short timestamp (e.g. `2:14 PM`) appears in the gutter where the avatar would otherwise be. This trades persistent timestamps for visual calm without losing the data — you can always recover it with a hover.

## 3. Sender labels

The display name renders inline at the start of the group header, **tinted by the member's highest-priority role colour** ([Discord roles & permissions](https://support.discord.com/hc/en-us/articles/214836687-Discord-Roles-and-Permissions)). To the right of the name, dim secondary text shows a long-form timestamp (`Today at 2:14 PM`). Follow-up messages within the group have no name and no inline timestamp — the hover-timestamp in the gutter is the only time signal.

Per-role colour is **Discord-specific**: it depends on a server role hierarchy we don't have. Echo could keep a single accent colour per author (deterministic hash → palette) to get the same scanability benefit without inventing roles.

## 4. Grouping rules

Discord groups consecutive messages when **(a) same author, (b) no other sender interleaved, (c) sent within ~7 minutes of the previous message** ([community discussion of the grouping change](https://support.discord.com/hc/en-us/community/posts/12799818806551-Undo-the-recent-change-to-message-grouping)). A grouped run gets minimal vertical spacing between rows (just line-height). Between two groups Discord inserts a larger vertical gap (~17px) so the eye can find author boundaries. The 7-minute heuristic is a good Echo default; the exact value is less important than picking one and treating it as a budget.

## 5. Cozy vs Compact mode

Discord ships two density presets ([COMPOZY userstyle reference](https://userstyles.org/styles/129570/compozy-a-cleaner-cozier-more-compact-discord), [community feedback](https://support.discord.com/hc/en-us/community/posts/6226580777239-Keep-old-compact-mode-as-an-option-resolved)):

- **Cozy** (default): avatar gutter visible, name + timestamp on a separate header line above the body, generous padding.
- **Compact**: no avatar, each message renders as a single line — `[HH:MM] DisplayName body…` — with smaller name text and reduced vertical padding. Optimised for high-throughput reading (logs, fast servers).

Reasoning: power users in active servers want IRC-density; casual users want breathing room. Two presets, one toggle, no in-between.

## 6. Edit / reactions / replies

- **Edited**: a dim `(edited)` marker appears inline at the end of the message body. Hovering it shows the edit timestamp.
- **Reactions**: render as small pill chips in a wrap row directly under the message body, each chip showing emoji + count. The user's own reactions are tinted; clicking a chip toggles your reaction.
- **Reply**: replied-to messages render a **compact quoted preview line above the new message** (small avatar, name, single-line truncated body). Clicking the preview scrolls to the original.

## 7. System events & dividers

- **Unread divider**: a thin red horizontal rule with the label `New` appears above the first unread message in the channel.
- **Day divider**: a thin grey horizontal rule with the date centred (`December 14, 2026`) splits the list at midnight boundaries.
- **Join/leave/pin events**: rendered as single-line system rows with a small left-side glyph (arrow, pin, etc.) and muted text — they sit in the flow but visibly differ from author messages.

## 8. First message in a brand-new channel

Discord renders a **welcome card** at the very top of an empty channel: a large `#` icon, a heading `Welcome to #channel-name!`, and a subtitle `This is the start of the #channel-name channel.`. It anchors the scroll and doubles as onboarding copy. Directly applicable to Echo's "Start of group" idea — same purpose, replace `#channel` with group/DM context.

## 9. Self vs others

Discord makes **no visual distinction for your own messages**. Your row uses your display name, your avatar, the same layout and colour as everyone else's row. There is no "You" label and no right-alignment. Reasoning: in multi-party chat the author identity matters; in two-party SMS it's redundant, which is why bubble apps right-align self. For a group-first product like ours, Discord's treatment is the right default.

## 10. Hover toolbar

On message hover, a floating chip strip appears at the **top-right of the row, slightly overlapping the message** ([hover toolbar feedback](https://support.discord.com/hc/en-us/community/posts/9426030716951-Hovering-over-a-message-that-is-a-reply-to-a-message-covers-reply-so-you-can-t-navigate-to-it)). Default order: three quick-reaction emoji, an emoji-picker `+` button, then an ellipsis menu for reply/forward/edit/delete/copy-link/etc. ([reactions FAQ](https://support.discord.com/hc/en-us/articles/12102061808663-Reactions-and-Super-Reactions-FAQ)). Hover-only keeps the resting list calm; the strip lifts on a subtle shadow so it reads as floating rather than inline.

Caveat from Discord's own users: the toolbar can occlude the inline reply-preview chip when hovering a reply, which is a known issue — worth designing around (e.g. shifting the toolbar down a few pixels when a reply preview is present).

---

## Sources

- [Discord Roles and Permissions](https://support.discord.com/hc/en-us/articles/214836687-Discord-Roles-and-Permissions)
- [Reactions and Super Reactions FAQ](https://support.discord.com/hc/en-us/articles/12102061808663-Reactions-and-Super-Reactions-FAQ)
- [Discord Display Name Styles FAQ](https://support.discord.com/hc/en-us/articles/33833879643927-Discord-Display-Name-Styles-FAQ)
- [Enhanced Role Styles](https://support.discord.com/hc/en-us/articles/31444213087255-Enhanced-Role-Styles)
- [Community: Undo the recent change to message grouping (7-min rule)](https://support.discord.com/hc/en-us/community/posts/12799818806551-Undo-the-recent-change-to-message-grouping)
- [Community: Keep old compact mode as an option](https://support.discord.com/hc/en-us/community/posts/6226580777239-Keep-old-compact-mode-as-an-option-resolved)
- [Community: Hover toolbar covers reply preview](https://support.discord.com/hc/en-us/community/posts/9426030716951-Hovering-over-a-message-that-is-a-reply-to-a-message-covers-reply-so-you-can-t-navigate-to-it)
- [COMPOZY userstyle — secondary description of Cozy vs Compact diff](https://userstyles.org/styles/129570/compozy-a-cleaner-cozier-more-compact-discord)
