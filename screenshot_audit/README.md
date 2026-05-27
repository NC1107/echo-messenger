# Screenshot audit

Visual baseline of every user-facing surface across the three beta themes.
Used to spot hardcoded colours, text-on-accent contrast, layout drift, and
theme-specific regressions before each release.

## Themes captured

| Slug | Label | Notes |
|------|-------|-------|
| `indigo` | Indigo | Default dark. Navy + violet accent. |
| `paper` | Paper | Default light. Warm off-white. |
| `ember` | Ember | Amber on warm black. |

Other themes (graphite, sakura, highContrast) live in the codebase but are
not shipped in the beta picker, so they are out of scope for this audit.

## Layout

```
screenshot_audit/
  {theme}/
    auth/      login, register, server-picker
    home/      conv list, sidebar states, search overlays
    chat/      DM, group, threads, reactions, hover
    group/     info, members, invite, discover, create
    voice/     lounge states, spotlight, screen share
    canvas/    drawing menu, color picker, bg dialog
    settings/  each section panel
    modals/    confirm, sheet, toast, what's new
```

PNGs are gitignored — only the directory + per-area README is tracked. Each
area's README enumerates the screens to capture and what the auditor should
verify in each one.

## How to run

1. Start the local server: `./scripts/run.sh`
2. Build + serve the web client on `:8081`:
   ```
   cd apps/client && flutter build web --release --pwa-strategy=none
   cd build/web && python3 -m http.server 8081
   ```
3. From repo root: `cd tests/e2e && npx playwright test audit_tour.spec.ts`
4. PNGs land under `screenshot_audit/{theme}/{area}/{screen}.png`.

Re-run any single theme with `--grep`:
```
npx playwright test audit_tour.spec.ts --grep indigo
```

## Audit format

For each PNG that has an issue, append a row to `findings.md` in the area
folder:

```
| Theme | Screen | Issue | Severity |
|-------|--------|-------|----------|
| ember | drawing-menu.png | Highlight chip text contrast 2.4:1 (AA needs 4.5:1) | high |
```

Severities: **blocker** (broken UI, unreadable), **high** (WCAG fail or
clearly off-brand), **medium** (looks fine but inconsistent with rest of
app), **low** (nice-to-have).

## What to look for, per screen

- **Hardcoded white/black** — text on accent buttons, badges, dialogs
- **Contrast** — pinned text, status pills, hover states meet WCAG AA (4.5:1)
- **Borders + dividers** — invisible in one theme, garish in another
- **Sent-message bubble** — uses theme accent, not a hardcoded blue
- **Icons** — readable on both surface and surface-hover backgrounds
- **Toast / sheet shadows** — depth visible in light theme
- **Empty-state illustrations** — legible at default text-secondary alpha
