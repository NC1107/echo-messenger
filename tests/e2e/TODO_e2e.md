# E2E Test TODO

## Blocked by Flutter Web CanvasKit limitation (#188)

- **Reply to specific message**: The hover Reply button activates the reply indicator (confirmed via screenshot + `dismiss reply preview` semantic label), but after the hover overlay click, Flutter's text editing host desynchronizes with the shadow DOM input. Typing produces garbled text. Requires Flutter-side fix (ensure `requestFocus()` properly syncs the browser text editing channel after hover overlay interaction).

## Planned tests (not yet implemented)

- Multiline message tests
- Multiple reactions on a single message
- Group creation (Alice creates, Bob creates)
- Group invite (each user invites the other)
- Group owner permissions (verify only owner has owner controls)
- Group messaging (same messaging tests as DM but in group context)
- Group kick (owner kicks member)
- Group rejoin (kicked member rejoins)
- Group ban (owner bans member, verify they can't rejoin)
- Safety number comparison (extract and compare digits between users)
- Encrypted pinned message content verification
