/// Audit P1-1 acceptance tests: multi-client group-encryption protocol
/// scenarios driven by [FakeGroupServer] + [SimulatedGroupClient].
///
/// These scenarios cover the L4 (rotation never completes) and L9 (client
/// crashes mid-send) failure modes from
/// `docs/group-e2e-design/05-message-loss-analysis.md` that no unit test
/// can exercise on its own — they need multiple concurrent clients
/// sharing a server state.
///
/// Each scenario reads like a story: set up a roster, drive a sequence
/// of `triggerRotation`/`crash`/`partition` calls, and assert on which
/// clients can decrypt which messages.
library;

import 'package:flutter_test/flutter_test.dart';

import '../helpers/multi_client_group_harness.dart';

void main() {
  const conv = 'conv-alpha';
  late FakeGroupServer server;
  late SimulatedGroupClient alice;
  late SimulatedGroupClient bob;
  late SimulatedGroupClient charlie;

  setUp(() {
    server = FakeGroupServer();
    alice = SimulatedGroupClient(userId: 'alice', server: server);
    bob = SimulatedGroupClient(userId: 'bob', server: server);
    charlie = SimulatedGroupClient(userId: 'charlie', server: server);
    server.createConversation(conv, ['alice', 'bob', 'charlie']);
  });

  group('Group E2E simulation — happy path', () {
    test('3 clients round-trip after the initial rotation', () async {
      // Alice mints the first key version and distributes envelopes.
      final outcome = await alice.triggerRotation(conv);
      expect(outcome, RotationOutcome.accepted);

      // Bob + Charlie pull the active version off the server.
      expect(bob.pullActiveKey(conv), 0);
      expect(charlie.pullActiveKey(conv), 0);

      // Alice sends. Bob + Charlie decrypt.
      final wire = await alice.sendMessage(conv, 'hello group');
      expect(wire, isNotNull);
      expect(await bob.receiveMessage(conv, wire!), 'hello group');
      expect(await charlie.receiveMessage(conv, wire), 'hello group');
    });

    test('a member without a cached key cannot encrypt', () async {
      // No rotation triggered → no key on the server → nothing to cache.
      expect(server.activeVersion(conv), -1);
      final wire = await alice.sendMessage(conv, 'attempt');
      expect(
        wire,
        isNull,
        reason: 'sendMessage must refuse to fall back to plaintext',
      );
    });
  });

  group('Group E2E simulation — concurrent rotation race', () {
    test('audit L4: two rotators racing — UNIQUE constraint elects one winner '
        'and the loser sees versionAlreadyExists', () async {
      // Two members both observe activeVersion=-1 and independently
      // race to submit at version 0. In the real server the
      // "deterministic leader" optimisation should prevent this case
      // from being common, but the safety guarantee is the database
      // UNIQUE constraint, and *that* is what we test here. Pin
      // atVersion=0 on both so they actually collide instead of
      // serialising through `activeVersion + 1`.
      final aliceOutcome = await alice.triggerRotation(conv, atVersion: 0);
      final bobOutcome = await bob.triggerRotation(conv, atVersion: 0);

      expect(aliceOutcome, RotationOutcome.accepted);
      expect(bobOutcome, RotationOutcome.versionAlreadyExists);
      expect(server.activeVersion(conv), 0);
    });

    test('the rotation-loser recovers by pulling the winner\'s key', () async {
      // Alice + Bob both race at v0; Bob loses; pulls Alice's envelope.
      await alice.triggerRotation(conv, atVersion: 0);
      final loseOutcome = await bob.triggerRotation(conv, atVersion: 0);
      expect(loseOutcome, RotationOutcome.versionAlreadyExists);

      expect(bob.pullActiveKey(conv), 0);
      // Bob can now encrypt under the same key Alice has.
      final wire = await alice.sendMessage(conv, 'after race');
      expect(await bob.receiveMessage(conv, wire!), 'after race');
    });
  });

  group('Group E2E simulation — leader-only-online (audit L4)', () {
    test('when only the elected leader is online, rotation completes and '
        'offline followers pull on reconnect', () async {
      bob.partition();
      charlie.partition();

      // Alice is the only online member; she completes the rotation.
      expect(await alice.triggerRotation(conv), RotationOutcome.accepted);

      // Followers come back online and pull.
      bob.reconnect();
      charlie.reconnect();
      expect(bob.pullActiveKey(conv), 0);
      expect(charlie.pullActiveKey(conv), 0);

      final wire = await alice.sendMessage(conv, 'leader-only');
      expect(await bob.receiveMessage(conv, wire!), 'leader-only');
      expect(await charlie.receiveMessage(conv, wire), 'leader-only');
    });

    test('partitioned client trying to rotate returns networkUnavailable '
        'without touching server state', () async {
      alice.partition();
      final outcome = await alice.triggerRotation(conv);
      expect(outcome, RotationOutcome.networkUnavailable);
      expect(server.activeVersion(conv), -1, reason: 'server untouched');
    });
  });

  group('Group E2E simulation — all-crash-mid-rotation (audit L4)', () {
    test('when no rotator completes, the group is wedged — but the next '
        'online member can rotate to recover', () async {
      // Both Alice and Bob are online but crash before either reaches
      // the server. (We model this by NOT calling triggerRotation.)
      // The group has no active key version.
      expect(server.activeVersion(conv), -1);

      // Crash Alice + Bob mid-flight. Charlie, who was idle, comes
      // online and is now the only member who can rotate.
      alice.crash();
      bob.crash();

      // Charlie rotates and recovers the group.
      expect(await charlie.triggerRotation(conv), RotationOutcome.accepted);
      expect(server.activeVersion(conv), 0);

      // Alice and Bob restart, re-pull, and join the new version.
      alice.restart();
      bob.restart();
      expect(alice.pullActiveKey(conv), 0);
      expect(bob.pullActiveKey(conv), 0);

      final wire = await charlie.sendMessage(conv, 'recovered');
      expect(await alice.receiveMessage(conv, wire!), 'recovered');
      expect(await bob.receiveMessage(conv, wire), 'recovered');
    });
  });

  group('Group E2E simulation — membership change rotation', () {
    test('audit L2: a removed member cannot decrypt the new key version, '
        'but can still decrypt messages encrypted under the old version '
        'they had access to', () async {
      await alice.triggerRotation(conv);
      bob.pullActiveKey(conv);
      charlie.pullActiveKey(conv);

      // Send something at v0 that everyone can read.
      final wireV0 = await alice.sendMessage(conv, 'before kick');
      expect(await charlie.receiveMessage(conv, wireV0!), 'before kick');

      // Kick Charlie + rotate.
      server.removeMember(conv, 'charlie');
      final rotateOutcome = await alice.triggerRotation(
        conv,
        excludingMembers: {'charlie'},
      );
      expect(rotateOutcome, RotationOutcome.accepted);
      bob.pullActiveKey(conv);

      // Alice encrypts at v1 — Charlie cannot decrypt.
      final wireV1 = await alice.sendMessage(conv, 'after kick');
      // Charlie still holds his v0 key, so decrypting v1-encrypted
      // wire returns null. He has no envelope at v1 either.
      expect(await charlie.receiveMessage(conv, wireV1!), isNull);
      // Charlie also can't sync to v1.
      expect(
        charlie.pullActiveKey(conv),
        -1,
        reason: 'no envelope at v1 for a removed member',
      );
      // But Bob (still a member) can.
      expect(await bob.receiveMessage(conv, wireV1), 'after kick');

      // And Charlie's pre-kick history is still readable for him.
      expect(await charlie.receiveMessage(conv, wireV0), 'before kick');
    });

    test(
      'a removed member trying to trigger a fresh rotation gets notAMember',
      () async {
        await alice.triggerRotation(conv);
        bob.pullActiveKey(conv);
        charlie.pullActiveKey(conv);

        server.removeMember(conv, 'charlie');

        final outcome = await charlie.triggerRotation(conv);
        expect(outcome, RotationOutcome.notAMember);
        // Active version still v0; no audit entry for an accepted
        // rotation by a removed member.
        expect(server.activeVersion(conv), 0);
        final acceptedByCharlie = server.rotationLog
            .where(
              (e) =>
                  e.submitterId == 'charlie' &&
                  e.outcome == RotationOutcome.accepted,
            )
            .toList();
        expect(acceptedByCharlie, isEmpty);
      },
    );
  });

  group('Group E2E simulation — audit-log observability (audit OQ-13)', () {
    test('rotation log records every accepted + rejected attempt', () async {
      // Race at v0: Alice wins, Bob loses.
      await alice.triggerRotation(conv, atVersion: 0);
      await bob.triggerRotation(conv, atVersion: 0);
      // Now kick Charlie; her rotation attempt is rejected as notAMember.
      server.removeMember(conv, 'charlie');
      await charlie.triggerRotation(conv);

      expect(server.rotationLog.length, 3);
      expect(server.rotationLog.map((e) => e.outcome).toList(), [
        RotationOutcome.accepted,
        RotationOutcome.versionAlreadyExists,
        RotationOutcome.notAMember,
      ]);
    });
  });
}
