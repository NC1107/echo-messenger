# Echo Messenger Style Sheet

This document is the UI style sheet for Echo Messenger. It is intended to be the design-side source of truth for Figma work, frontend polish, and future UI cleanup across the Flutter client.

It is based on the current theme system in `/apps/client/lib/src/theme/echo_theme.dart` and the current chat shell component patterns in the client widgets.

## Design Direction

Echo should feel:
- compact, dense, and communication-first
- closer to Discord and Slack than to consumer chat apps with oversized chrome
- structured and technical, not playful by default
- theme-flexible without losing component consistency

The base visual language is:
- low-noise surfaces
- strong contrast between navigation, content, and action layers
- restrained radius and shadow usage
- high legibility at dense sizes
- accent color used for action and state, not decoration overload

## Typography

Primary font family:
- Inter

Font usage comes from the app text theme and should stay consistent across all screens.

### Type Scale

| Token | Size | Weight | Use |
|---|---:|---:|---|
| `headlineLarge` | 24 | 700 | Major page headings, onboarding hero headings |
| `headlineMedium` | 22 | 700 | Section headings, large settings titles |
| `titleLarge` | 16 | 600 | Dialog titles, major panel titles |
| `titleMedium` | 14 | 600 | Conversation titles, row headings, compact section headings |
| `bodyLarge` | 15 | 400 | Main readable body copy, message text |
| `bodyMedium` | 13 | 400 | Secondary body text, settings rows, search text |
| `bodySmall` | 12 | 400 | Metadata, status text, timestamps |
| `labelLarge` | 11 | 600 | Eyebrow labels, pinned/group section labels |

### Typography Rules

- Do not go below `12px` for readable UI metadata unless there is a very strong reason.
- Message text should remain at `15px`.
- Secondary control labels should prefer `13px`.
- Timestamps, status labels, and low-priority metadata should prefer `12px`.
- Use `11px` only for compact labels, not for primary readable content.
- Weight should do more work than size. Prefer `600` over unnecessary size inflation.

## Color Roles

Every theme should expose the same semantic roles.

### Required Semantic Tokens

| Role | Purpose |
|---|---|
| `mainBg` | App-level background |
| `sidebarBg` | Left rail / navigation background |
| `chatBg` | Main chat canvas |
| `surface` | Cards, menus, fields, elevated panels |
| `surfaceHover` | Hover layer over surface items |
| `accent` | Primary action color |
| `accentHover` | Hover/stronger accent state |
| `accentLight` | Selected background / subtle accent tint |
| `textPrimary` | Main readable text |
| `textSecondary` | Secondary text and icon color |
| `textMuted` | Low-priority metadata |
| `sentBubble` | Outgoing message bubble |
| `recvBubble` | Incoming message bubble |
| `border` | Divider and input border color |
| `online` | Presence success color |
| `warning` | Warning and degraded-state color |
| `danger` | Destructive action color |

### Base Theme Palette

| Token | Hex |
|---|---|
| `mainBg` | `#0A0A0B` |
| `sidebarBg` | `#0F0F10` |
| `chatBg` | `#141415` |
| `surface` | `#1C1C1E` |
| `surfaceHover` | `#232326` |
| `accent` | `#5557E0` |
| `accentHover` | `#818CF8` |
| `accentLight` | `#1A5557E0` |
| `textPrimary` | `#EDEDEF` |
| `textSecondary` | `#ABABB0` |
| `textMuted` | `#848490` |
| `sentBubble` | `#5254D4` |
| `recvBubble` | `#242428` |
| `border` | `#27272A` |
| `online` | `#22C55E` |
| `warning` | `#F59E0B` |
| `danger` | `#EF4444` |

## Theme Sheet

These are the approved theme variants currently represented in the app.

### Dark

| Role | Hex |
|---|---|
| Main | `#0A0A0B` |
| Sidebar | `#0F0F10` |
| Surface | `#1C1C1E` |
| Accent | `#5557E0` |
| Text Primary | `#EDEDEF` |
| Text Secondary | `#ABABB0` |

### Light

| Role | Hex |
|---|---|
| Main | `#F5F5F7` |
| Sidebar | `#F0F0F3` |
| Surface | `#FAFAFC` |
| Accent | `#5557E0` |
| Text Primary | `#1A1A1E` |
| Text Secondary | `#5C5C66` |

### Graphite

| Role | Hex |
|---|---|
| Main | `#0B1114` |
| Sidebar | `#101A1F` |
| Surface | `#1A2A32` |
| Accent | `#13AF9D` |
| On Accent | `#0A1114` |
| Text Primary | `#E7F4F8` |
| Text Secondary | `#A3BAC2` |

### Ember

| Role | Hex |
|---|---|
| Main | `#110E0A` |
| Sidebar | `#171310` |
| Surface | `#252019` |
| Accent | `#E9960A` |
| On Accent | `#110E0A` |
| Text Primary | `#F5F0E8` |
| Text Secondary | `#A89F91` |

### Neon

| Role | Hex |
|---|---|
| Main | `#0A0A0F` |
| Sidebar | `#0D0D14` |
| Surface | `#14141E` |
| Accent | `#00FF88` |
| On Accent | `#0A0A0F` |
| Text Primary | `#E0E0E8` |
| Text Secondary | `#A0A0B8` |

Note:
Neon must use dark foreground text on accent surfaces. White on `#00FF88` is not acceptable.

### Aurora

| Role | Hex |
|---|---|
| Main | `#0D0B14` |
| Sidebar | `#110E1A` |
| Surface | `#1A1628` |
| Accent | `#8458E9` |
| Text Primary | `#EDE9F6` |
| Text Secondary | `#ABA4BE` |

### Sakura

| Role | Hex |
|---|---|
| Main | `#FFF5F7` |
| Sidebar | `#FFF0F3` |
| Surface | `#FFFAFC` |
| Accent | `#DD1C85` |
| Text Primary | `#2D1B2E` |
| Text Secondary | `#7B5A7E` |

## Spacing Scale

Use a compact spacing system.

### Core Spacing Tokens

| Token | Value | Use |
|---|---:|---|
| `space-2` | 2 | icon-group gaps, micro separation |
| `space-4` | 4 | tiny row gaps, chip spacing |
| `space-6` | 6 | compact inline gaps |
| `space-8` | 8 | default small gap |
| `space-10` | 10 | avatar-to-text gap, status rows |
| `space-12` | 12 | control padding, compact section padding |
| `space-16` | 16 | panel horizontal padding |
| `space-24` | 24 | large panel padding |
| `space-32` | 32 | empty-state and major section spacing |

### Layout Rules

- Primary horizontal panel padding should default to `16px`.
- Search, banners, and section blocks should align to the same `16px` edge.
- Vertical rhythm in compact list surfaces should usually be `4px`, `8px`, or `12px`.
- Do not mix many arbitrary values when a token already exists.

## Radius

Rounded corners should stay restrained.

| Token | Value | Use |
|---|---:|---|
| `radius-6` | 6 | tooltips |
| `radius-8` | 8 | snackbars, small menus, compact banners |
| `radius-10` | 10 | search bars, buttons, chips, list selection states |
| `radius-12` | 12 | dialogs, bottom sheets |
| `radius-14` | 14 | pill chips only |

## Icon Scale

| Size | Use |
|---:|---|
| `14` | inline supportive icon only |
| `16` | context menus, destructive actions, compact metadata icon |
| `18` | primary toolbar, row actions, navigation controls |
| `20` | default theme icon size |
| `22` | logo mark |
| `24+` | hero or empty-state iconography |

Rules:
- Do not use `12px` icons for important state.
- Prefer `18px` for actionable shell controls.
- If an icon is interactive, target at least a `40x40` touch area and ideally `44x44`.

## Elevation and Borders

Echo is border-led more than shadow-led.

### Border Rules

- Default border width: `1px`
- Dividers should use the semantic `border` token
- Inputs, cards, and menus should use border contrast before adding shadow

### Shadow Rules

- Avoid heavy shadows in dark themes
- Light and Sakura can use subtle shadow for tooltips and floating surfaces
- Shadows should support separation, not define the whole component language

## Component Patterns

### Sidebar Shell

- Height of shell header: `56px`
- Height of user status bar: `56px`
- Shared left/right padding: `16px`
- Header title size: `17px`, weight `700`
- Primary shell icons: `18px`

### Search Bar

- Height: `44px`
- Radius: `10px`
- Search text: `13px`
- Placeholder text: `13px`

### Filter Chips

- Visual chip height: `28px`
- Hit area: minimum `44px` tall
- Label size: `12px`
- Radius: `14px`
- Selected state: accent background with `onPrimary` text

### Conversation Rows

- Dense layout first
- Timestamp should be right-aligned with no artificial “floating” slot
- Pinned state should use icon plus ordering, not color overload
- Row metadata should not fall below `12px`
- Compact mode should preserve avatar continuity when that mode is active

### Context Menus

- Label size: `13px`
- Icon size: `16px`
- Use destructive color only for destructive actions
- Use semantic labels like `Mute` / `Unmute`, `Leave Group`, `Delete Conversation`

### Dialogs

- Title size: `18px`
- Body size: `14px`
- Radius: `12px`
- Destructive confirmation uses `danger`

### Buttons

- Filled button text: `14px`, weight `600`
- Outlined buttons used for secondary path in empty states and settings
- Default button radius: `10px`
- Padding target: `20px` horizontal, `14px` vertical for primary filled buttons

### Banners

- Height: `56px` when used as compact system banner
- Warning/replaced session states should use warning border and icon, not full red

## Accessibility Rules

- Minimum readable metadata size: `12px`
- Minimum interactive touch target: `40x40`, target `44x44`
- Theme accents must pass contrast with their foreground text
- Focus-visible states should use `accentLight` or equivalent visible selection tint
- Status should not rely on color alone when short text can clarify state

## Motion

Motion should be minimal and purposeful.

- Use short transitions around `150ms` to `200ms`
- Prefer opacity and simple container swaps over elaborate motion
- Animated state changes should clarify structure, not entertain

## Writing Style for UI

- Use short, direct labels
- Prefer verbs for actions: `Mute`, `Unmute`, `Leave`, `Delete`, `Retry`
- Avoid marketing copy in primary product surfaces
- Empty states should be concise and functional

## Figma Handoff Conventions

If this style sheet is turned into Figma assets, use these page/group buckets:

- `00 Foundations`
- `01 Themes`
- `02 Components`
- `03 Chat Shell`
- `04 Conversation List`
- `05 Message Composer`
- `06 States and Empty States`
- `07 Settings`

Suggested Figma token groups:

- `color.bg.*`
- `color.surface.*`
- `color.text.*`
- `color.accent.*`
- `color.status.*`
- `type.*`
- `space.*`
- `radius.*`
- `icon.*`

## Implementation Note

This style sheet should stay aligned with:
- `/apps/client/lib/src/theme/echo_theme.dart`
- the core chat widgets in `/apps/client/lib/src/widgets/`

When UI tokens change in code, this document should be updated in the same change.