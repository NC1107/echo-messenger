# Hive cache corruption on hard-kill (issue #1182)

## What can happen

Echo uses [Hive](https://pub.dev/packages/hive) as an on-device message cache.
If the OS sends `SIGKILL` (or the user force-quits) while Hive is mid-write,
the `.hive` box file can be left in a partially-written state.

## Affected data

**Only the local message cache.** Every message is server-ACK'd before it is
written to Hive, so no unsent or received message is ever lost. Corruption
only affects the performance cache that pre-fills the chat history pane on
cold start. Affected conversations reload from the server automatically.

Saved bookmarks (Saved Messages) are also stored in Hive. A corrupt bookmarks
box is wiped and started fresh — bookmarks themselves are lost, but the app
launches normally.

## Mitigation added in 0.0.x (#1182)

Three layers of defence were added:

1. **Flush on pause.** `ShutdownHandler` awaits `MessageCache.flushAll()` when
   the OS raises `AppLifecycleState.paused` — one lifecycle beat before
   `detached`. This drains any buffered writes before the process is eligible
   for SIGKILL.

2. **Time-boxed close.** On `AppLifecycleState.detached` (and on SIGTERM),
   `Hive.close()` is raced against a 500 ms deadline via `Future.any`. The
   write window where corruption can occur is minimal after step 1; the
   timeout prevents stalling the OS shutdown sequence indefinitely.

3. **Corrupt-box recovery on launch.** If a box file is unreadable (Hive
   throws on open), the file is deleted and an empty box is opened in its
   place. The user sees an empty cache that fills back in from the server,
   rather than a crash loop.

## Remaining risk

A `SIGKILL` that arrives between steps 1 and 2 — i.e. during the `Hive.close()`
window after flush has completed — can still produce a corrupt frame header in
the box file. Step 3 recovers from this on the next launch.

A SIGKILL that interrupts step 1 before `flushAll()` completes can, in theory,
corrupt in-flight writes. This is the residual risk acknowledged when choosing
option 1 (best-effort) over option 2 (WAL-backed sqflite) in issue #1182.

## Future work

- **Option 2:** Migrate the message cache to sqflite with WAL journal mode.
  WAL gives atomic commits, so a mid-write kill cannot corrupt the database.
  Tracked in issue #1182 (option 2 — out of scope for this PR).
- **Option 3:** Move Hive to a background isolate that can install a SIGTERM
  handler and fsync before acknowledging. Also tracked in #1182.
