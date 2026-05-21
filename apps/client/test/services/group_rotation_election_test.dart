/// Phase 3b — server-led leader election helpers on the client.
///
/// Pins the pure-function contract that decides "do I attempt this
/// rotation, and if so when?" without exercising the
/// `GroupCryptoService.performRotation` HTTP path. The integration with
/// `_handleGroupKeyRotationRequested` is a thin shim over these helpers;
/// the rotation crypto itself is covered by
/// `group_crypto_service_rotation_test.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/services/group_rotation_election.dart';

void main() {
  group('rotationAttemptDelay', () {
    const me = 'me-uuid';
    const leader = 'leader-uuid';
    const peerA = 'peerA-uuid';
    const peerB = 'peerB-uuid';

    test('leader fires immediately', () {
      final d = rotationAttemptDelay(
        leaderUserId: me,
        fallbackOrder: const [peerA, peerB],
        deadlineMs: 7500,
        myUserId: me,
      );
      expect(d, Duration.zero);
      expect(d, noRotationDelay);
    });

    test('first fallback waits one deadline window', () {
      final d = rotationAttemptDelay(
        leaderUserId: leader,
        fallbackOrder: const [me, peerB],
        deadlineMs: 7500,
        myUserId: me,
      );
      expect(d, const Duration(milliseconds: 7500));
    });

    test('second fallback waits two deadline windows', () {
      final d = rotationAttemptDelay(
        leaderUserId: leader,
        fallbackOrder: const [peerA, me],
        deadlineMs: 5000,
        myUserId: me,
      );
      expect(d, const Duration(milliseconds: 10000));
    });

    test('user not in elected set returns null', () {
      // The local client was not online at the time the server snapshotted.
      // It must NOT join the fallback race — that would defeat the
      // server's stampede control.
      final d = rotationAttemptDelay(
        leaderUserId: leader,
        fallbackOrder: const [peerA, peerB],
        deadlineMs: 7500,
        myUserId: me,
      );
      expect(d, isNull);
    });

    test(
      'legacy event without leader_user_id preserves race-all semantics',
      () {
        // Pre-Phase-3b servers send no leader hint. Clients must fall back
        // to "every online member races immediately" so a mixed-fleet
        // rollout cannot wedge an encrypted group.
        final d = rotationAttemptDelay(
          leaderUserId: null,
          fallbackOrder: const [],
          deadlineMs: 7500,
          myUserId: me,
        );
        expect(d, Duration.zero);
      },
    );

    test('empty leader_user_id also falls back to race-all', () {
      final d = rotationAttemptDelay(
        leaderUserId: '',
        fallbackOrder: const [],
        deadlineMs: 7500,
        myUserId: me,
      );
      expect(d, Duration.zero);
    });
  });

  group('shouldAbortRotation', () {
    test('aborts when cache caught up to target', () {
      expect(shouldAbortRotation(currentVersion: 5, targetVersion: 5), isTrue);
    });

    test('aborts when cache leapfrogged the target', () {
      // The server could have triggered a follow-up rotation while we
      // were waiting in the fallback queue — current > target means
      // somebody beat us twice over.
      expect(shouldAbortRotation(currentVersion: 6, targetVersion: 5), isTrue);
    });

    test('does not abort when cache is stale', () {
      expect(shouldAbortRotation(currentVersion: 4, targetVersion: 5), isFalse);
    });

    test('does not abort when no key cached', () {
      // No envelope locally; we *must* attempt our own upload — waiting
      // for a phantom peer would wedge the group.
      expect(
        shouldAbortRotation(currentVersion: null, targetVersion: 5),
        isFalse,
      );
    });
  });

  group('parseRotationRequested', () {
    test('parses full Phase 3b payload', () {
      final req = parseRotationRequested({
        'conversation_id': 'conv-1',
        'key_version': 3,
        'leader_user_id': 'leader-uuid',
        'fallback_order': ['peerA-uuid', 'peerB-uuid'],
        'deadline_ms': 5000,
      });
      expect(req, isNotNull);
      expect(req!.conversationId, 'conv-1');
      expect(req.keyVersion, 3);
      expect(req.leaderUserId, 'leader-uuid');
      expect(req.fallbackOrder, ['peerA-uuid', 'peerB-uuid']);
      expect(req.deadlineMs, 5000);
    });

    test('falls back to default deadline when missing', () {
      final req = parseRotationRequested({
        'conversation_id': 'conv-1',
        'key_version': 3,
      });
      expect(req, isNotNull);
      expect(req!.deadlineMs, defaultRotationDeadlineMs);
      expect(req.leaderUserId, isNull);
      expect(req.fallbackOrder, isEmpty);
    });

    test('rejects non-positive deadline values', () {
      // A hostile peer cannot force every client to race immediately by
      // sending deadline_ms=0 — the parser substitutes the default.
      final req = parseRotationRequested({
        'conversation_id': 'conv-1',
        'key_version': 3,
        'deadline_ms': 0,
      });
      expect(req!.deadlineMs, defaultRotationDeadlineMs);

      final neg = parseRotationRequested({
        'conversation_id': 'conv-1',
        'key_version': 3,
        'deadline_ms': -100,
      });
      expect(neg!.deadlineMs, defaultRotationDeadlineMs);
    });

    test('returns null when conversation_id missing', () {
      expect(parseRotationRequested({'key_version': 3}), isNull);
    });

    test('returns null when key_version missing', () {
      expect(parseRotationRequested({'conversation_id': 'conv-1'}), isNull);
    });

    test('returns null when conversation_id empty', () {
      expect(
        parseRotationRequested({'conversation_id': '', 'key_version': 3}),
        isNull,
      );
    });

    test('ignores non-string entries in fallback_order', () {
      final req = parseRotationRequested({
        'conversation_id': 'conv-1',
        'key_version': 3,
        'fallback_order': ['peerA', 42, null, 'peerB'],
      });
      expect(req!.fallbackOrder, ['peerA', 'peerB']);
    });
  });
}
