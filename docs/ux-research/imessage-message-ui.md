# iMessage Message List UI — Research Notes

Reference notes on how Apple Messages (iOS 17+/macOS Sonoma+) renders its message list, intended to inform our Flutter chat redesign. Sources: Apple HIG Messages page (https://developer.apple.com/design/human-interface-guidelines/messages), Apple Messages user guide (https://support.apple.com/guide/messages/), and secondary teardowns by Sebastiaan de With (https://blog.halide.cam) and Luke Wroblewski's chat UX writeups (https://lukew.com/ff/entry.asp?1939).

## 1. Bubble Layout
Bubbles are pill-shaped with ~18 px corner radius and a small "tail" pointing to the sender side on the **last** bubble of a consecutive run only. Sent bubbles align right with **iMessage blue** (#007AFF-ish) or **SMS green** (#34C759-ish); received bubbles align left with system gray (#E9E9EB light / #262628 dark). Text is white on blue/green, label color on gray. Max bubble width is roughly 75% of the available column. Internal padding is ~10 px vertical, ~12 px horizontal. The blue/green/gray triad is load-bearing — it's the only protocol signal in the UI. **Translates well** to Flutter; the tail is the only fiddly bit (custom `BubbleClipper` or a `CustomPainter`).

## 2. Avatars
1:1 chats show **no avatars in the message list** — identity is implied by side alignment and the navigation bar's avatar at top center. Group chats show small (~28 px) circular avatars on the left **only on the last bubble** of a run from that sender. Tapping a bubble or scrolling does not collapse avatars; they're always rendered at the same position. **Translates well**, and avatar-only-on-last-of-run is a cheap clarity win.

## 3. Sender Labels
Sender name appears **above the first bubble of a run** in group chats, in a small caption-style gray label (~12 pt, secondary label color), indented to align with the bubble's leading edge. Never shown in 1:1. Never shown on subsequent bubbles in a run. **Translates well.**

## 4. Grouping & Spacing
Consecutive bubbles from the same sender are **tightly stacked** (~2 px gap) and share an alignment edge; the corners facing the neighbor are squared off (~4 px radius) while the outer corners keep the full ~18 px radius, producing a "stacked pills" look. Different-sender transitions get a larger ~8–10 px gap. Only the final bubble in a run draws the tail. This visual rhythm is what makes long iMessage threads scan-able. **Translates well** but requires per-bubble state ("is first in run / is last in run / is alone") passed from the list builder — worth a small helper.

## 5. Timestamp Behavior
Inline timestamps are rare. iMessage inserts a **full-row centered timestamp divider** (e.g. "Mon 3:42 PM") whenever a gap of roughly **>15 minutes (>1h after the first one of the session)** opens between messages. The killer pattern is **swipe-left-to-reveal**: dragging the message list horizontally exposes a right-edge column of exact send times for every bubble, which springs back on release (iOS only; macOS shows times on hover). **Partially translates** — the gap-based divider is trivial; the swipe-reveal column is doable on touch but feels weird on desktop, so we'd want hover-to-reveal there.

## 6. Read Receipts / Status
Status text sits **below the last sent bubble only**, right-aligned, in tiny secondary-label gray: "Delivered", or "Read 3:42 PM" if the recipient has read receipts on. As soon as the sender posts another message, the previous "Delivered/Read" disappears and only the new last bubble carries status. No checkmarks, no per-bubble status. **Translates well** and is far less noisy than WhatsApp/Telegram tick marks.

## 7. Reactions (Tapbacks)
Six fixed reactions (heart, thumbs up/down, haha, !!, ?). Rendered as a small **circular badge overhanging the top-outer corner** of the bubble (top-left on sent, top-right on received), in the bubble's own color family. Multiple reactors stack with a count. They never reflow the bubble or push it down. **Translates well** and matches the "reactions overhang the far edge" note already in our project memory.

## 8. System Events / Dividers
Centered, full-row, ~12 pt secondary-label text. Used for date breaks ("Yesterday", "Monday", or "Mon, May 26"), "Read receipts turned on", and Tapback summaries on macOS. No background pill, no rule lines — just centered text with generous vertical padding (~16 px). **Translates well.**

## 9. Empty Group / First-Conversation State
iMessage shows a **large centered group avatar cluster** (overlapping member avatars) plus the group name and an "iMessage" subtitle, with no messages and no placeholder copy. Tapping the avatar cluster opens group details. There's no "Say hi!" call to action. The blankness itself signals "fresh thread." **Translates well** and is a nice antidote to the AI-generated "Start the conversation!" empty states.

## 10. First-of-Day / First-of-Group Divider
Critically, **iMessage does not show a "Today" label** for the current day's first message — the assumption is that the most recent message is from today. The first divider you see is for the **previous** day ("Yesterday") once you scroll up past today's messages, then day-of-week ("Monday"), then full date for older. The first message of a new sender-run within the same time window gets only the sender label (§3), not a divider. **Translates well** and saves vertical space versus Slack/Discord's always-on day headers — recommend we adopt this rule rather than mirror Slack.

## 11. Density / Compactness Controls
- iMessage does **not** expose a Cozy / Compact toggle the way Slack and Discord do. Density on iOS/macOS is controlled at the OS level: the system Dynamic Type setting scales text up/down, and Reduce Motion / Reduce Transparency adjust the bubble feel.
- Bubble vertical rhythm is fixed: ~2 px gap within a same-sender run, ~8–10 px between senders. The app's "compactness" comes entirely from the run-length grouping logic + Dynamic Type — there is no separate density preset.
- macOS Messages uses a tighter list-row look (smaller avatars, less inter-row padding) by default than iOS, but neither offers a user-facing preference.
- **Translation to Echo:** treat density as an Echo-side preset rather than something iMessage informs directly. The lesson is that *good defaults* matter more than offering a toggle — iMessage hits a single tight default and lives with it.

## 12. Channel Navigation (Sidebar vs Top Bar)
- iMessage has **no concept of channels** within a conversation. Each conversation (1:1 or group) is a single message stream — there is no "general" / "voice" / "off-topic" sub-channel split. The left sidebar lists *conversations*, not channels within a conversation.
- The closest analogue is iOS's per-conversation **details pane** (tap the conversation header), which surfaces attachments, links, and shared photos — adjacent to the message stream but not navigation.
- **Translation to Echo:** because iMessage is single-stream, none of its message-UI patterns depend on whether channels are presented as a left sidebar or top tabs. The grouping, divider, and timestamp behaviour all work identically regardless of the channel-nav choice. If Echo chooses top-tab channels (like the screenshot showing `general | lounge` at the top), the message stream below those tabs can lift iMessage's patterns 1:1.

**Summary:** the channel-nav choice (left sidebar vs top tabs) does not affect any of the message-list patterns documented above from iMessage.
