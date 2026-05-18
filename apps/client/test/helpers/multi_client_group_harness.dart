/// In-process simulation harness for group-encryption protocol scenarios.
///
/// Built for audit P1-1. The QA review flagged that L4 (rotation never
/// completes) and L9 (client crashes mid-send) from
/// `docs/group-e2e-design/05-message-loss-analysis.md` cannot be
/// exercised by unit tests against a single client — they require
/// multiple concurrent clients sharing a server state.
///
/// What this harness models faithfully:
///   * The server's `(conversation_id, key_version)` UNIQUE constraint
///     — first writer wins, others see "version already exists".
///   * Per-version envelope storage keyed by `(convId, version, memberId)`.
///   * Membership changes (add / remove) gated server-side.
///   * Client-side state: current cached key version per conversation,
///     per-conv connectivity (online / partitioned / crashed).
///
/// What this harness intentionally stubs:
///   * Real ECDH envelope wrapping — envelopes are stored as opaque
///     `MemberEnvelope` records that the simulated server hands to the
///     intended recipient verbatim. Real envelope wrapping correctness
///     is covered by `group_crypto_service` unit tests, and would only
///     add noise here without testing more behaviour.
///   * Real HTTP. The harness drives the server's methods directly.
///   * Real network latency. Scenarios can choose to interleave method
///     calls to model concurrency; nothing happens between awaits.
///
/// Use [SimulatedGroupClient.sendMessage] + [receiveMessage] for round
/// trips. Use [triggerRotation], [crash], [partition], and [reconnect]
/// to set up failure scenarios.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:echo_app/src/services/group_crypto_service.dart';

/// Outcome of a rotation attempt against [FakeGroupServer].
enum RotationOutcome {
  /// Server accepted the new key version. Caller is the rotator-of-record.
  accepted,

  /// Another rotator already submitted this version. Loser of the race.
  versionAlreadyExists,

  /// The submitter is no longer a member (e.g. concurrently removed).
  notAMember,

  /// Caller's connectivity is currently partitioned or crashed.
  networkUnavailable,
}

/// One envelope row, as the real server's `group_key_envelopes` table
/// would store it: `(conversation_id, member_id, key_version) → ciphertext`.
class MemberEnvelope {
  MemberEnvelope({
    required this.conversationId,
    required this.memberId,
    required this.keyVersion,
    required this.envelopeBlob,
  });

  final String conversationId;
  final String memberId;
  final int keyVersion;

  /// Opaque ciphertext blob. The simulation uses the unwrapped key bytes
  /// directly (see [SimulatedGroupClient._unwrap]) rather than performing
  /// real ECDH, because the realistic envelope-wrap path is covered by
  /// `group_crypto_service.dart` unit tests already.
  final Uint8List envelopeBlob;
}

/// In-memory stand-in for the server's group-key tables + endpoints.
class FakeGroupServer {
  /// `(convId, version, memberId) → envelope`.
  final Map<String, MemberEnvelope> _envelopes = {};

  /// Active key version per conversation. -1 means no key has been minted.
  final Map<String, int> _activeVersion = {};

  /// Membership rosters per conversation.
  final Map<String, Set<String>> _members = {};

  /// Audit log of every rotation attempt (success or rejection).
  final List<RotationLogEntry> rotationLog = [];

  /// Set up a fresh conversation with a starting member roster.
  void createConversation(String conversationId, Iterable<String> memberIds) {
    _members[conversationId] = memberIds.toSet();
    _activeVersion[conversationId] = -1;
  }

  /// Add a member mid-flight. Does NOT trigger rotation — that's the
  /// caller's responsibility, matching the real server's contract.
  void addMember(String conversationId, String memberId) {
    _members.putIfAbsent(conversationId, () => {}).add(memberId);
  }

  /// Remove a member mid-flight. Does NOT trigger rotation.
  void removeMember(String conversationId, String memberId) {
    _members[conversationId]?.remove(memberId);
  }

  /// Currently-active key version, or -1 if none has been minted.
  int activeVersion(String conversationId) =>
      _activeVersion[conversationId] ?? -1;

  /// Current member roster (returns a snapshot copy).
  Set<String> members(String conversationId) =>
      Set<String>.from(_members[conversationId] ?? const {});

  /// Look up the envelope for `memberId` at `keyVersion`. Returns null when
  /// the member was excluded from that version (e.g. they were removed
  /// before the rotation, or the rotation hasn't published yet).
  MemberEnvelope? getEnvelope(
    String conversationId,
    int keyVersion,
    String memberId,
  ) {
    return _envelopes['$conversationId|$keyVersion|$memberId'];
  }

  /// Submit a candidate new key version with per-member envelopes.
  ///
  /// Implements the real server's `(conversation_id, key_version)` UNIQUE
  /// guarantee: the first writer wins, every other writer at the same
  /// version sees [RotationOutcome.versionAlreadyExists] and is expected
  /// to retry against the new active version.
  RotationOutcome submitKeyVersion({
    required String submitterId,
    required String conversationId,
    required int keyVersion,
    required Map<String, Uint8List> envelopesByMember,
  }) {
    final roster = _members[conversationId];
    if (roster == null || !roster.contains(submitterId)) {
      rotationLog.add(
        RotationLogEntry(
          conversationId: conversationId,
          submitterId: submitterId,
          keyVersion: keyVersion,
          outcome: RotationOutcome.notAMember,
        ),
      );
      return RotationOutcome.notAMember;
    }

    final existing = _activeVersion[conversationId] ?? -1;
    if (keyVersion <= existing) {
      // Server enforces "key_version must be strictly greater than active".
      // In the real schema this falls out of the UNIQUE constraint plus
      // the active_version pointer.
      rotationLog.add(
        RotationLogEntry(
          conversationId: conversationId,
          submitterId: submitterId,
          keyVersion: keyVersion,
          outcome: RotationOutcome.versionAlreadyExists,
        ),
      );
      return RotationOutcome.versionAlreadyExists;
    }

    // Accept: write every envelope and bump the active pointer.
    for (final entry in envelopesByMember.entries) {
      _envelopes['$conversationId|$keyVersion|${entry.key}'] = MemberEnvelope(
        conversationId: conversationId,
        memberId: entry.key,
        keyVersion: keyVersion,
        envelopeBlob: entry.value,
      );
    }
    _activeVersion[conversationId] = keyVersion;
    rotationLog.add(
      RotationLogEntry(
        conversationId: conversationId,
        submitterId: submitterId,
        keyVersion: keyVersion,
        outcome: RotationOutcome.accepted,
      ),
    );
    return RotationOutcome.accepted;
  }
}

/// One row of the server's rotation audit log.
class RotationLogEntry {
  RotationLogEntry({
    required this.conversationId,
    required this.submitterId,
    required this.keyVersion,
    required this.outcome,
  });
  final String conversationId;
  final String submitterId;
  final int keyVersion;
  final RotationOutcome outcome;
}

/// A simulated group-encryption client. Wraps the real static
/// `encryptGroupMessage` + `decryptGroupMessage` for the wire-level math
/// and adds: local key-cache state, connectivity simulation, crash
/// simulation, and an out-of-band [pullActiveKey] sync that drains a
/// new key version from the server.
class SimulatedGroupClient {
  SimulatedGroupClient({required this.userId, required this.server});

  final String userId;
  final FakeGroupServer server;

  /// `convId -> (cachedVersion, cachedKey)`. Populated by [pullActiveKey]
  /// after a rotation OR by being the rotator yourself.
  final Map<String, (int, String)> _cachedKey = {};

  bool _crashed = false;
  bool _partitioned = false;

  // ── Failure-mode controls used by tests ────────────────────────────────

  /// Simulate the process being killed — drops the in-memory key cache.
  /// Subsequent reads MUST go back to disk/server (in this harness, to
  /// the server via [pullActiveKey]). Used for the L9 crash-recovery
  /// scenarios.
  void crash() {
    _crashed = true;
    _cachedKey.clear();
  }

  /// Restart from a crash. Cache is empty; client needs to re-pull active
  /// keys before it can send or receive.
  void restart() {
    _crashed = false;
  }

  /// Simulate a network partition — server-bound operations fail with
  /// [RotationOutcome.networkUnavailable] until [reconnect] is called.
  void partition() {
    _partitioned = true;
  }

  /// End a partition.
  void reconnect() {
    _partitioned = false;
  }

  bool get isOnline => !_partitioned && !_crashed;

  /// Number of cached key versions (test introspection).
  int get cachedKeyCount => _cachedKey.length;

  // ── Send / receive ─────────────────────────────────────────────────────

  /// Encrypt + emit a wire frame. Returns null when the client has no
  /// cached key for this conversation (caller should [pullActiveKey] first).
  Future<String?> sendMessage(String conversationId, String plaintext) async {
    if (_crashed) throw StateError('client crashed');
    final entry = _cachedKey[conversationId];
    if (entry == null) return null;
    return GroupCryptoService.encryptGroupMessage(plaintext, entry.$2);
  }

  /// Decrypt a wire frame. Returns null when the client has no cached
  /// key (or wrong version) for this conversation.
  Future<String?> receiveMessage(String conversationId, String wire) async {
    if (_crashed) throw StateError('client crashed');
    final entry = _cachedKey[conversationId];
    if (entry == null) return null;
    try {
      return await GroupCryptoService.decryptGroupMessage(wire, entry.$2);
    } catch (_) {
      return null;
    }
  }

  // ── Server sync ────────────────────────────────────────────────────────

  /// Fetch the active key version from the server and unwrap into the
  /// local cache. Returns the version that was pulled, or -1 on failure
  /// (no version available, not a member, partitioned, etc.).
  int pullActiveKey(String conversationId) {
    if (!isOnline) return -1;
    final activeVersion = server.activeVersion(conversationId);
    if (activeVersion < 0) return -1;
    final envelope = server.getEnvelope(conversationId, activeVersion, userId);
    if (envelope == null) return -1; // not a recipient at this version
    _cachedKey[conversationId] = (
      activeVersion,
      _unwrap(envelope.envelopeBlob),
    );
    return activeVersion;
  }

  /// Trigger a rotation. Generates a new symmetric key, wraps it for each
  /// supplied recipient (here: stores the key bytes verbatim as the
  /// "envelope" — the real implementation does ECDH-wrap per identity
  /// public key), and submits to the server. Returns the server's
  /// outcome.
  ///
  /// `excludingMembers` models a "kick + rotate" sequence: the removed
  /// member's identity is left out of the new envelope set.
  ///
  /// `atVersion` lets test code pin the target version. Without it, the
  /// client picks `activeVersion + 1` at submit time — fine for sequential
  /// scenarios, but useless for race tests where two clients must both
  /// pick the same target version before either submits. Pass an explicit
  /// version to interleave submissions.
  Future<RotationOutcome> triggerRotation(
    String conversationId, {
    Set<String>? excludingMembers,
    int? atVersion,
  }) async {
    if (!isOnline) return RotationOutcome.networkUnavailable;
    final newKey = GroupCryptoService.generateGroupKey();
    final keyBytes = base64Decode(newKey);

    final roster = server.members(conversationId);
    final recipients = excludingMembers == null
        ? roster
        : roster.difference(excludingMembers);

    final targetVersion = atVersion ?? server.activeVersion(conversationId) + 1;
    final envelopes = <String, Uint8List>{
      for (final m in recipients) m: keyBytes,
    };
    final outcome = server.submitKeyVersion(
      submitterId: userId,
      conversationId: conversationId,
      keyVersion: targetVersion,
      envelopesByMember: envelopes,
    );

    if (outcome == RotationOutcome.accepted) {
      _cachedKey[conversationId] = (targetVersion, newKey);
    }
    return outcome;
  }

  /// Internal: "unwrap" a stored envelope into the raw key string. The
  /// real implementation runs ECDH + AES-GCM-unwrap here; the simulation
  /// stores the key bytes verbatim, so unwrapping is a base64 encode.
  String _unwrap(Uint8List envelope) => base64Encode(envelope);
}
