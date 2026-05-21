/// Client-side helpers for the server-led leader-election protocol that
/// kicks off a group-key rotation (Phase 3b, see
/// `docs/group-e2e-design/03-recommended-protocol.md`).
///
/// The server picks a leader from the online subset of the group, ships
/// it on the `group_key_rotation_requested` WS event alongside a sorted
/// `fallback_order` and a `deadline_ms` hint. Each client reads the event
/// and decides — based on its own user_id's position in the
/// `[leader, ...fallback_order]` priority list — how long to wait before
/// attempting to upload envelopes itself.
///
/// The functions here are deliberately pure: no `dart:io`, no HTTP, no
/// timers. The caller composes them with `Future.delayed` and the
/// existing [`GroupCryptoService.performRotation`] / `getGroupKey` paths.
/// That makes them cheap to unit-test against synthetic priority lists
/// without spinning up a Riverpod container or mocking secure storage.
library;

/// Outcome of [rotationAttemptDelay] when the local user is the chosen
/// leader. Sentinel value distinct from any positive wait.
const Duration noRotationDelay = Duration.zero;

/// Default deadline used by the client when the server omits the
/// `deadline_ms` field. Mirrors `DEFAULT_ROTATION_DEADLINE_MS` in
/// `apps/server/src/ws/rotation.rs`; if the server side moves, this
/// constant should move with it so legacy / cross-version messages still
/// behave consistently.
const int defaultRotationDeadlineMs = 7_500;

/// Decide how long the local client should wait before attempting a
/// rotation, given the server-elected `leader`, the ordered fallback
/// list, the server's deadline hint, and the local user's own id.
///
/// Returns `null` when the local user is not part of either the leader or
/// the fallback list. That happens when the server snapshot did not see
/// this client as online (e.g. they connected between the trigger and
/// the broadcast, racing the WS hub registration). The handler should
/// treat `null` as "wait for the next `group_key_rotated` event but do
/// not start a competing rotation" — entering the fallback queue from
/// outside the elected set would defeat the very stampede-control the
/// server-led election was built to provide.
///
/// Returns `Duration.zero` when the local user is the leader: fire
/// immediately, no jitter.
///
/// Returns `Duration(milliseconds: deadlineMs * (1 + position))`
/// otherwise, where `position` is the zero-based index in
/// `fallbackOrder`. That gives the leader the first slot (0 ms), the
/// first fallback the second slot (`deadline_ms` ms), the second
/// fallback the third slot (`2 * deadline_ms` ms), and so on. Each
/// non-leader checks whether a winning envelope has appeared during its
/// wait — see [`shouldAbortRotation`] — before actually attempting to
/// upload.
Duration? rotationAttemptDelay({
  required String? leaderUserId,
  required List<String> fallbackOrder,
  required int deadlineMs,
  required String myUserId,
}) {
  if (leaderUserId == null || leaderUserId.isEmpty) {
    // Pre-Phase-3b events have no leader hint. Preserve the legacy
    // behaviour of "every online client races immediately". Returning
    // zero here keeps the existing UNIQUE-constraint-as-safety-net
    // semantics — exactly what the code path did before this slice.
    return Duration.zero;
  }
  if (myUserId == leaderUserId) {
    return noRotationDelay;
  }
  final position = fallbackOrder.indexOf(myUserId);
  if (position < 0) {
    return null;
  }
  // +1 because the leader occupies slot 0; the first fallback slot
  // starts at `deadlineMs`.
  final waitMs = deadlineMs * (position + 1);
  return Duration(milliseconds: waitMs);
}

/// Returns true if a freshly-fetched group key version has caught up to
/// the rotation target — meaning *some* peer (the leader, an earlier
/// fallback, or a parallel trigger) already completed the rotation and
/// the local client should NOT attempt its own competing upload.
///
/// Callers pass:
/// - `currentVersion`: the version they observe right now (from
///   `getGroupKey` after invalidating the cache);
/// - `targetVersion`: the version baked into the
///   `group_key_rotation_requested` event.
///
/// A `null` current version means "no key cached and the server has no
/// envelope for us" — the receiver should attempt the rotation itself
/// rather than wait for one that has clearly not happened. Any non-null
/// current version `>= targetVersion` means the rotation already
/// completed and we should abort.
bool shouldAbortRotation({
  required int? currentVersion,
  required int targetVersion,
}) {
  if (currentVersion == null) return false;
  return currentVersion >= targetVersion;
}

/// Convenience: parse a `group_key_rotation_requested` payload into the
/// fields the client uses, applying sane defaults for pre-Phase-3b
/// payloads (no leader, no fallback, default deadline). Returns `null`
/// when the payload is missing the mandatory `conversation_id` or
/// `key_version`. Validates `deadline_ms` is positive — a non-positive
/// value collapses the staggering and is treated as "missing", letting
/// the client fall back to the default.
RotationRequest? parseRotationRequested(Map<String, dynamic> json) {
  final conversationId = json['conversation_id'] as String?;
  final keyVersion = (json['key_version'] as num?)?.toInt();
  if (conversationId == null || conversationId.isEmpty || keyVersion == null) {
    return null;
  }
  final leaderUserId = json['leader_user_id'] as String?;
  final rawFallback = json['fallback_order'];
  final fallbackOrder = rawFallback is List
      ? rawFallback.whereType<String>().toList(growable: false)
      : const <String>[];
  final rawDeadline = (json['deadline_ms'] as num?)?.toInt();
  final deadlineMs = (rawDeadline != null && rawDeadline > 0)
      ? rawDeadline
      : defaultRotationDeadlineMs;
  return RotationRequest(
    conversationId: conversationId,
    keyVersion: keyVersion,
    leaderUserId: leaderUserId,
    fallbackOrder: fallbackOrder,
    deadlineMs: deadlineMs,
  );
}

/// Immutable view of a parsed `group_key_rotation_requested` payload.
class RotationRequest {
  final String conversationId;
  final int keyVersion;
  final String? leaderUserId;
  final List<String> fallbackOrder;
  final int deadlineMs;

  const RotationRequest({
    required this.conversationId,
    required this.keyVersion,
    required this.leaderUserId,
    required this.fallbackOrder,
    required this.deadlineMs,
  });
}
