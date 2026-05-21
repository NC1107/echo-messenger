// Unit tests covering the freshly-split chat_provider part files:
//   - chat_state.dart        (ChatState + helpers, decrypt-failure tracking)
//   - chat_edits.dart        (markConversationRead / delete / edit / pin / forward)
//   - chat_reactions.dart    (addReaction / removeReaction)
//   - chat_recovery.dart     (resetWedgedSession / refreshGroupKey /
//                             dismissSignatureFailure / addSystemEvent)
//   - chat_history.dart      (loadFromCache happy path; full HTTP fetch is
//                             exercised by chat_cold_start_hydration_test.dart)
//
// The existing chat_provider_test.dart + chat_notifier_*_test.dart cover the
// hot path (addMessage, send/confirm/timeout, status transitions, reply
// counts). These tests fill the remaining gaps the audit (#1057) called out
// when the god-module was split.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/reaction.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/crypto_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:echo_app/src/services/crypto_service.dart';
import 'package:echo_app/src/services/group_crypto_service.dart';
import 'package:echo_app/src/services/message_cache.dart';

import '../helpers/mock_providers.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a ChatMessage with minimal noise. Anything you don't set picks a sane
/// default (conv-1, alice, non-mine, sent, 2026-01-01 timestamp). Use named
/// args to override the bits each test cares about.
ChatMessage _msg(
  String id, {
  String conversationId = 'conv-1',
  String? channelId,
  String content = 'hello',
  String fromUserId = 'u-alice',
  String fromUsername = 'alice',
  bool isMine = false,
  MessageStatus status = MessageStatus.sent,
  String timestamp = '2026-01-01T00:00:00Z',
  List<Reaction> reactions = const [],
}) {
  return ChatMessage(
    id: id,
    fromUserId: fromUserId,
    fromUsername: fromUsername,
    conversationId: conversationId,
    channelId: channelId,
    content: content,
    timestamp: timestamp,
    isMine: isMine,
    status: status,
    reactions: reactions,
  );
}

ProviderContainer _container({List<Override> extra = const []}) {
  final c = ProviderContainer(
    overrides: [
      authProvider.overrideWith(
        () => FakeLoggedInAuthNotifier(
          const AuthState(
            isLoggedIn: true,
            userId: 'me',
            username: 'testuser',
            token: 'fake-token',
          ),
        ),
      ),
      serverUrlProvider.overrideWith(
        () => FakeServerUrlNotifier('http://localhost:8080'),
      ),
      ...extra,
    ],
  );
  return c;
}

// ---------------------------------------------------------------------------
// chat_state.dart — extra coverage for placeholder + filtering branches
// ---------------------------------------------------------------------------

void _chatStateGroup() {
  group('chat_state — withMessage placeholder replace', () {
    test('placeholder "Securing message..." is replaced in place when '
        'the real message arrives with the same id (#430)', () {
      final placeholder = _msg(
        'm1',
        content: 'Securing message...',
      ).copyWith(isEncrypted: true);
      final real = _msg('m1', content: 'actual plaintext');

      final s = const ChatState().withMessage(placeholder).withMessage(real);
      final msgs = s.messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(msgs.first.content, 'actual plaintext');
    });

    test('"[Encrypted for another device of this account]" placeholder is '
        'also replaceable (multi-device path)', () {
      final placeholder = _msg(
        'm1',
        content: '[Encrypted for another device of this account]',
      ).copyWith(isEncrypted: true);
      final real = _msg('m1', content: 'plain');
      final s = const ChatState().withMessage(placeholder).withMessage(real);
      expect(s.messagesForConversation('conv-1').first.content, 'plain');
    });

    test('an existing non-encrypted entry with the same id is NOT replaced — '
        'avoids dropping confirmed text under a duplicate-id race', () {
      // Non-encrypted incumbent (regular content, isEncrypted: false).
      final incumbent = _msg('m1', content: 'first text');
      // Same id, even with "real" content — the existing path must stick.
      final dup = _msg('m1', content: 'second text');
      final s = const ChatState().withMessage(incumbent).withMessage(dup);
      expect(s.messagesForConversation('conv-1').first.content, 'first text');
    });

    test('withMessage on an empty conversationId is a no-op', () {
      final ghost = _msg('m1').copyWith(conversationId: '');
      final s = const ChatState().withMessage(ghost);
      expect(s.messagesByConversation, isEmpty);
    });

    test('signature-failure placeholder marks the conversation as wedged', () {
      final sig = _msg('m1', content: '[Could not verify sender]');
      final s = const ChatState().withMessage(sig);
      expect(s.hasSignatureFailure('conv-1'), isTrue);
      // hasSignatureFailure is sticky across follow-on good messages.
      final ok = _msg('m2', content: 'genuine text');
      final s2 = s.withMessage(ok);
      expect(s2.hasSignatureFailure('conv-1'), isTrue);
    });

    test(
      'withSignatureFailureCleared removes only the named conv from the set',
      () {
        var s = const ChatState();
        s = s.withMessage(
          _msg('m1', conversationId: 'A', content: '[Could not verify sender]'),
        );
        s = s.withMessage(
          _msg('m2', conversationId: 'B', content: '[Could not verify sender]'),
        );
        expect(s.hasSignatureFailure('A'), isTrue);
        expect(s.hasSignatureFailure('B'), isTrue);

        final cleared = s.withSignatureFailureCleared('A');
        expect(cleared.hasSignatureFailure('A'), isFalse);
        expect(cleared.hasSignatureFailure('B'), isTrue);
      },
    );

    test(
      'withSignatureFailureCleared is a no-op when the flag was never set',
      () {
        const s = ChatState();
        // Should return `this` unchanged — identity check is the strongest
        // guarantee we don't allocate on the happy path.
        expect(identical(s.withSignatureFailureCleared('conv-X'), s), isTrue);
      },
    );

    test('a system event between failures does not reset the counter', () {
      // System events are filtered out of the decrypt-failure reset path so
      // a "alice joined" pill landing between two undecryptable placeholders
      // doesn't accidentally hide the out-of-sync banner.
      var s = const ChatState();
      s = s.withMessage(
        _msg('f1', content: '[Could not decrypt - keys out of sync]'),
      );
      s = s.withMessage(
        _msg(
          's1',
          content: 'alice joined the group',
          fromUserId: ChatMessage.systemUserId,
          fromUsername: 'System',
        ),
      );
      s = s.withMessage(
        _msg('f2', content: '[Could not decrypt - keys out of sync]'),
      );
      // The system event must not touch the counter.
      expect(s.consecutiveDecryptFailures['conv-1'], 2);
    });
  });
}

// ---------------------------------------------------------------------------
// chat_edits.dart — markRead / delete / edit / pin / forward
// ---------------------------------------------------------------------------

void _chatEditsGroup() {
  group('chat_edits — markConversationRead', () {
    test(
      'only sweeps my own sent/delivered — failed and sending are untouched',
      () {
        final n = _container().read(chatProvider.notifier);
        n.addMessage(_msg('m1', isMine: true, status: MessageStatus.sent));
        n.addMessage(_msg('m2', isMine: true, status: MessageStatus.failed));
        n.addMessage(_msg('m3', isMine: true, status: MessageStatus.sending));
        n.markConversationRead('conv-1');

        final msgs = n.state.messagesForConversation('conv-1');
        expect(msgs.firstWhere((m) => m.id == 'm1').status, MessageStatus.read);
        expect(
          msgs.firstWhere((m) => m.id == 'm2').status,
          MessageStatus.failed,
          reason: 'failed messages must not be silently marked read',
        );
        expect(
          msgs.firstWhere((m) => m.id == 'm3').status,
          MessageStatus.sending,
          reason: 'sending messages must not be silently marked read',
        );
      },
    );

    test('does not affect a sibling conversation', () {
      final n = _container().read(chatProvider.notifier);
      n.addMessage(
        _msg(
          'm1',
          conversationId: 'A',
          isMine: true,
          status: MessageStatus.sent,
        ),
      );
      n.addMessage(
        _msg(
          'm2',
          conversationId: 'B',
          isMine: true,
          status: MessageStatus.sent,
        ),
      );
      n.markConversationRead('A');
      final aMsg = n.state.messagesForConversation('A').single;
      final bMsg = n.state.messagesForConversation('B').single;
      expect(aMsg.status, MessageStatus.read);
      expect(bMsg.status, MessageStatus.sent);
    });
  });

  group('chat_edits — deleteMessage', () {
    test(
      'rebuilds the dedup index — re-adding the same id works after delete',
      () {
        final n = _container().read(chatProvider.notifier);
        final m = _msg('m1');
        n.addMessage(m);
        n.deleteMessage('conv-1', 'm1');
        // Without the index rebuild, this re-add would silently dedup-drop.
        n.addMessage(m);
        expect(n.state.messagesForConversation('conv-1'), hasLength(1));
      },
    );

    test('unknown conversation id is a no-op (no throw)', () {
      final n = _container().read(chatProvider.notifier);
      expect(
        () => n.deleteMessage('conv-unknown', 'm-unknown'),
        returnsNormally,
      );
    });
  });

  group('chat_edits — editMessage', () {
    test('auto-generates editedAt when caller does not supply one', () {
      final n = _container().read(chatProvider.notifier);
      n.addMessage(_msg('m1', isMine: true, content: 'before'));
      n.editMessage('conv-1', 'm1', 'after');
      final edited = n.state.messagesForConversation('conv-1').single;
      expect(edited.content, 'after');
      expect(edited.editedAt, isNotNull);
      // ISO-8601 round-trip — must parse without throwing.
      expect(() => DateTime.parse(edited.editedAt!), returnsNormally);
    });

    test('unknown message id is a no-op', () {
      final n = _container().read(chatProvider.notifier);
      n.addMessage(_msg('m1', content: 'unchanged'));
      n.editMessage('conv-1', 'm-nope', 'replaced');
      expect(
        n.state.messagesForConversation('conv-1').single.content,
        'unchanged',
      );
    });

    test('unknown conversation id is a no-op', () {
      final n = _container().read(chatProvider.notifier);
      expect(() => n.editMessage('conv-unknown', 'm1', 'x'), returnsNormally);
    });
  });

  group('chat_edits — updateMessagePin', () {
    test('pinning is idempotent — repeat calls with the same args produce the '
        'same state', () {
      final n = _container().read(chatProvider.notifier);
      n.addMessage(_msg('m1'));
      final t = DateTime.parse('2026-01-15T12:00:00Z');
      n.updateMessagePin('conv-1', 'm1', 'admin', t);
      final first = n.state.messagesForConversation('conv-1').single;
      n.updateMessagePin('conv-1', 'm1', 'admin', t);
      final second = n.state.messagesForConversation('conv-1').single;
      expect(first.pinnedById, 'admin');
      expect(first.pinnedAt, t);
      expect(second.pinnedById, 'admin');
      expect(second.pinnedAt, t);
    });

    test('only the named message is mutated; siblings stay untouched', () {
      final n = _container().read(chatProvider.notifier);
      n.addMessage(_msg('m1'));
      n.addMessage(_msg('m2', timestamp: '2026-01-01T00:00:01Z'));
      final t = DateTime.parse('2026-01-15T12:00:00Z');
      n.updateMessagePin('conv-1', 'm1', 'admin', t);
      final msgs = n.state.messagesForConversation('conv-1');
      expect(msgs.firstWhere((m) => m.id == 'm1').pinnedById, 'admin');
      expect(msgs.firstWhere((m) => m.id == 'm2').pinnedById, isNull);
    });
  });

  group('chat_edits — forwardMessage', () {
    test('invokes the supplied sender with a "[Forwarded] " prefix', () async {
      final n = _container().read(chatProvider.notifier);
      String? captured;
      await n.forwardMessage('check this out', 'conv-target', (
        forwarded,
      ) async {
        captured = forwarded;
      });
      expect(captured, '[Forwarded] check this out');
    });

    test('an empty source still produces "[Forwarded] " prefix', () async {
      final n = _container().read(chatProvider.notifier);
      String? captured;
      await n.forwardMessage('', 'conv-target', (f) async {
        captured = f;
      });
      expect(captured, '[Forwarded] ');
    });
  });
}

// ---------------------------------------------------------------------------
// chat_reactions.dart — addReaction / removeReaction
// ---------------------------------------------------------------------------

void _chatReactionsGroup() {
  group('chat_reactions', () {
    test(
      'two distinct emojis from the same user coexist on the same message',
      () {
        final n = _container().read(chatProvider.notifier);
        n.addMessage(_msg('m1'));
        n.addReaction(
          'conv-1',
          const Reaction(
            messageId: 'm1',
            userId: 'u1',
            username: 'alice',
            emoji: '👍',
          ),
        );
        n.addReaction(
          'conv-1',
          const Reaction(
            messageId: 'm1',
            userId: 'u1',
            username: 'alice',
            emoji: '❤',
          ),
        );
        final reactions = n.state
            .messagesForConversation('conv-1')
            .single
            .reactions;
        expect(reactions, hasLength(2));
        expect(reactions.map((r) => r.emoji), containsAll(['👍', '❤']));
      },
    );

    test('addReaction with the same (user, emoji) twice keeps a single entry — '
        'remove-then-add is the contract', () {
      final n = _container().read(chatProvider.notifier);
      n.addMessage(_msg('m1'));
      const r = Reaction(
        messageId: 'm1',
        userId: 'u1',
        username: 'alice',
        emoji: '👍',
      );
      n.addReaction('conv-1', r);
      n.addReaction('conv-1', r); // duplicate
      final reactions = n.state
          .messagesForConversation('conv-1')
          .single
          .reactions;
      expect(reactions, hasLength(1));
    });

    test(
      'removeReaction does not touch a different emoji from the same user',
      () {
        final n = _container().read(chatProvider.notifier);
        n.addMessage(
          _msg(
            'm1',
            reactions: const [
              Reaction(
                messageId: 'm1',
                userId: 'u1',
                username: 'alice',
                emoji: '👍',
              ),
              Reaction(
                messageId: 'm1',
                userId: 'u1',
                username: 'alice',
                emoji: '❤',
              ),
            ],
          ),
        );
        n.removeReaction('conv-1', 'm1', 'u1', '👍');
        final reactions = n.state
            .messagesForConversation('conv-1')
            .single
            .reactions;
        expect(reactions, hasLength(1));
        expect(reactions.single.emoji, '❤');
      },
    );

    test(
      'removeReaction with no matching (user, emoji) leaves state alone',
      () {
        final n = _container().read(chatProvider.notifier);
        n.addMessage(
          _msg(
            'm1',
            reactions: const [
              Reaction(
                messageId: 'm1',
                userId: 'u1',
                username: 'alice',
                emoji: '👍',
              ),
            ],
          ),
        );
        n.removeReaction('conv-1', 'm1', 'someone-else', '😂');
        expect(
          n.state.messagesForConversation('conv-1').single.reactions,
          hasLength(1),
        );
      },
    );

    test('addReaction on an unknown conversation id is a safe no-op', () {
      final n = _container().read(chatProvider.notifier);
      expect(
        () => n.addReaction(
          'conv-unknown',
          const Reaction(
            messageId: 'm1',
            userId: 'u1',
            username: 'alice',
            emoji: '👍',
          ),
        ),
        returnsNormally,
      );
    });
  });
}

// ---------------------------------------------------------------------------
// chat_recovery.dart — resetWedgedSession / refreshGroupKey
// ---------------------------------------------------------------------------

/// A CryptoService that swallows `forceResetSession` so the recovery test
/// doesn't need SecureKeyStore. Subclasses the concrete class — the
/// chat_recovery code only calls one method.
class _RecordingCrypto extends CryptoService {
  _RecordingCrypto() : super(serverUrl: 'http://test.local');
  final List<String> resetCalls = [];
  @override
  Future<void> forceResetSession(String peerUserId) async {
    resetCalls.add(peerUserId);
  }
}

/// A GroupCryptoService that records `dropCachedKey` calls and lets the test
/// dictate what `getGroupKey` returns. We only need these two methods +
/// `cachedMinWireVersion` for the recovery path.
class _RecordingGroupCrypto extends GroupCryptoService {
  _RecordingGroupCrypto({this.keyToReturn})
    : super(serverUrl: 'http://test.local');

  /// What `getGroupKey` should yield. `null` triggers the self-heal path.
  (int, String)? keyToReturn;
  final List<String> dropCalls = [];
  int getCalls = 0;

  @override
  Future<void> dropCachedKey(String conversationId) async {
    dropCalls.add(conversationId);
  }

  @override
  Future<(int, String)?> getGroupKey(String conversationId) async {
    getCalls++;
    return keyToReturn;
  }
}

void _chatRecoveryGroup() {
  group('chat_recovery — resetWedgedSession', () {
    test(
      'calls crypto.forceResetSession and clears the wedged counter',
      () async {
        final fakeCrypto = _RecordingCrypto();
        final c = _container(
          extra: [cryptoServiceProvider.overrideWithValue(fakeCrypto)],
        );
        final n = c.read(chatProvider.notifier);

        // Plant the wedged state: cross the outOfSyncThreshold.
        n.state = n.state.copyWith(
          consecutiveDecryptFailures: {'conv-1': ChatState.outOfSyncThreshold},
        );
        expect(n.state.isConversationOutOfSync('conv-1'), isTrue);

        await n.resetWedgedSession('conv-1', 'peer-bob');

        expect(fakeCrypto.resetCalls, ['peer-bob']);
        expect(n.state.isConversationOutOfSync('conv-1'), isFalse);
        expect(
          n.state.consecutiveDecryptFailures.containsKey('conv-1'),
          isFalse,
        );
      },
    );

    test('clearing one wedged conv leaves others wedged', () async {
      final fakeCrypto = _RecordingCrypto();
      final c = _container(
        extra: [cryptoServiceProvider.overrideWithValue(fakeCrypto)],
      );
      final n = c.read(chatProvider.notifier);
      n.state = n.state.copyWith(
        consecutiveDecryptFailures: {
          'conv-1': ChatState.outOfSyncThreshold,
          'conv-2': ChatState.outOfSyncThreshold,
        },
      );
      await n.resetWedgedSession('conv-1', 'peer-bob');
      expect(n.state.isConversationOutOfSync('conv-1'), isFalse);
      expect(n.state.isConversationOutOfSync('conv-2'), isTrue);
    });
  });

  group('chat_recovery — refreshGroupKey', () {
    test('drops cached key, refetches, and clears the wedged counter when the '
        'server has an envelope', () async {
      final fakeGroup = _RecordingGroupCrypto(keyToReturn: (1, 'base64key=='));
      final c = _container(
        extra: [groupCryptoServiceProvider.overrideWithValue(fakeGroup)],
      );
      final n = c.read(chatProvider.notifier);
      n.state = n.state.copyWith(
        consecutiveDecryptFailures: {'conv-1': ChatState.outOfSyncThreshold},
      );

      await n.refreshGroupKey('conv-1');

      expect(fakeGroup.dropCalls, ['conv-1']);
      // First call hits the refetch; the no-self-heal branch should NOT
      // make a second call.
      expect(fakeGroup.getCalls, 1);
      expect(n.state.isConversationOutOfSync('conv-1'), isFalse);
    });

    test(
      'when the server has no envelope and self-heal throws, the counter '
      'is still cleared (the user shouldn\'t be stuck staring at the banner)',
      () async {
        // keyToReturn: null → refreshGroupKey tries seedInitialGroupKey,
        // which here errors (no real CryptoNotifier wired). The recovery
        // method catches and continues to withSyncRestored.
        final fakeGroup = _RecordingGroupCrypto(keyToReturn: null);
        final c = _container(
          extra: [groupCryptoServiceProvider.overrideWithValue(fakeGroup)],
        );
        final n = c.read(chatProvider.notifier);
        n.state = n.state.copyWith(
          consecutiveDecryptFailures: {'conv-1': ChatState.outOfSyncThreshold},
        );

        await n.refreshGroupKey('conv-1');

        expect(fakeGroup.dropCalls, ['conv-1']);
        expect(n.state.isConversationOutOfSync('conv-1'), isFalse);
      },
    );
  });

  group('chat_recovery — dismissSignatureFailure', () {
    test('clears the flag for one conv only', () {
      final n = _container().read(chatProvider.notifier);
      n.state = n.state.copyWith(signatureFailures: {'A', 'B'});
      n.dismissSignatureFailure('A');
      expect(n.state.signatureFailures, equals({'B'}));
    });
  });

  group('chat_recovery — addSystemEvent', () {
    test('appends through the standard withMessage path (system event surfaces '
        'in channel views too — see messagesForConversationChannel)', () {
      final n = _container().read(chatProvider.notifier);
      // Seed a channel-scoped message first so we can prove the system row
      // shows up in the channel filter.
      n.addMessage(_msg('m1', channelId: 'general'));
      n.addSystemEvent('conv-1', 'voice call started');
      final inChannel = n.state.messagesForConversationChannel(
        'conv-1',
        channelId: 'general',
      );
      // Two rows: the channel message + the system event.
      expect(inChannel, hasLength(2));
      expect(
        inChannel.where((m) => m.isSystemEvent).single.content,
        'voice call started',
      );
    });

    test('consecutive identical events ARE deduped (per the addSystemEvent '
        'contract — avoids duplicate "alice joined" rows when local state and '
        'the WS echo race)', () {
      final n = _container().read(chatProvider.notifier);
      n.addSystemEvent('conv-1', 'alice joined');
      n.addSystemEvent('conv-1', 'alice joined'); // duplicate
      final events = n.state
          .messagesForConversation('conv-1')
          .where((m) => m.isSystemEvent)
          .toList();
      expect(events, hasLength(1));
      expect(events.single.content, 'alice joined');
    });
  });
}

// ---------------------------------------------------------------------------
// chat_history.dart — loadFromCache happy path
// ---------------------------------------------------------------------------

void _chatHistoryGroup() {
  group('chat_history — loadFromCache', () {
    test(
      'merges cached messages into state preserving timestamp order',
      () async {
        const convId = 'conv-cache-1';
        const myId = 'me';
        // Seed the Hive cache directly.
        final older = const ChatMessage(
          id: 'older',
          fromUserId: 'peer',
          fromUsername: 'peer',
          conversationId: convId,
          content: 'older one',
          timestamp: '2026-01-01T00:00:00Z',
          isMine: false,
        );
        final newer = const ChatMessage(
          id: 'newer',
          fromUserId: 'peer',
          fromUsername: 'peer',
          conversationId: convId,
          content: 'newer one',
          timestamp: '2026-01-01T01:00:00Z',
          isMine: false,
        );
        await MessageCache.cacheMessages(convId, [newer, older]);

        final n = _container().read(chatProvider.notifier);
        expect(
          n.state.messagesByConversation.containsKey(convId),
          isFalse,
          reason: 'pre-condition: notifier starts empty',
        );

        await n.loadFromCache(convId, myId);

        final msgs = n.state.messagesForConversation(convId);
        expect(msgs, hasLength(2));
        // _mergeMessages sorts by timestamp asc.
        expect(msgs.first.id, 'older');
        expect(msgs.last.id, 'newer');
      },
    );

    test('an empty cache leaves state untouched', () async {
      const convId = 'conv-cache-empty';
      final n = _container().read(chatProvider.notifier);
      await n.loadFromCache(convId, 'me');
      expect(n.state.messagesByConversation.containsKey(convId), isFalse);
    });

    test('cached messages on top of in-memory ones do not duplicate', () async {
      const convId = 'conv-cache-dedup';
      const myId = 'me';
      final existing = const ChatMessage(
        id: 'shared',
        fromUserId: 'peer',
        fromUsername: 'peer',
        conversationId: convId,
        content: 'in memory',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      await MessageCache.cacheMessages(convId, [existing]);

      final n = _container().read(chatProvider.notifier);
      n.addMessage(existing);

      await n.loadFromCache(convId, myId);

      expect(n.state.messagesForConversation(convId), hasLength(1));
    });
  });
}

// ---------------------------------------------------------------------------
// Entry point — Hive is needed by loadFromCache; the other groups don't care.
// ---------------------------------------------------------------------------

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('chat_parts_test_');
    Hive.init(tempDir.path);
    await MessageCache.init();
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    await MessageCache.clearAll();
    await MessageCache.initForUser('me', 'localhost');
  });

  _chatStateGroup();
  _chatEditsGroup();
  _chatReactionsGroup();
  _chatRecoveryGroup();
  _chatHistoryGroup();
}
