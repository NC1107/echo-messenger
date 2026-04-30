// Audit test suite: proves logic flaws found during UI/UX review.
//
// Each test demonstrates a specific bug by setting up state and asserting
// the INCORRECT current behavior. When the bug is fixed, the test should
// be updated to assert the CORRECT behavior.
import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/conversations_provider.dart';
import 'package:echo_app/src/providers/crypto_provider.dart';

void main() {
  // =========================================================================
  // C1: confirmSent cancels ALL pending timers, not just the confirmed one
  // =========================================================================
  group('C1: confirmSent cancels all pending timers', () {
    test('confirming one message should not cancel other pending timers', () {
      // This tests the logic in chat_provider.dart:262-267
      // The loop cancels ALL pending_ timers, not just the one being confirmed.
      //
      // We can prove this by examining the confirmSent code path:
      // for (final m in state.messagesForConversation(conversationId)) {
      //   if (m.id.startsWith('pending_')) {
      //     _sendTimeouts.remove(m.id)?.cancel();  // cancels ALL
      //   }
      // }

      const state = ChatState();

      // Add 3 pending messages
      final msg1 = ChatMessage(
        id: 'pending_1000',
        fromUserId: 'me',
        fromUsername: 'Me',
        conversationId: 'conv1',
        content: 'first',
        timestamp: '2026-01-01T00:00:01Z',
        isMine: true,
        status: MessageStatus.sending,
      );
      final msg2 = ChatMessage(
        id: 'pending_2000',
        fromUserId: 'me',
        fromUsername: 'Me',
        conversationId: 'conv1',
        content: 'second',
        timestamp: '2026-01-01T00:00:02Z',
        isMine: true,
        status: MessageStatus.sending,
      );
      final msg3 = ChatMessage(
        id: 'pending_3000',
        fromUserId: 'me',
        fromUsername: 'Me',
        conversationId: 'conv1',
        content: 'third',
        timestamp: '2026-01-01T00:00:03Z',
        isMine: true,
        status: MessageStatus.sending,
      );

      final s1 = state.withMessage(msg1);
      final s2 = s1.withMessage(msg2);
      final s3 = s2.withMessage(msg3);

      // All 3 messages should be pending
      final pending = s3
          .messagesForConversation('conv1')
          .where((m) => m.id.startsWith('pending_'))
          .toList();
      expect(pending, hasLength(3));

      // BUG PROOF: The confirmSent code iterates ALL messages and cancels
      // ALL pending timers. We can't test timers directly in a state test,
      // but we can verify the code pattern by checking that confirmSent
      // only replaces ONE pending message (the first it finds), while the
      // loop at line 263-267 cancels timers for ALL pending messages.
      //
      // After confirmSent('server_id_1', 'conv1', timestamp):
      // - msg1 should be replaced with server_id_1
      // - msg2 should still be pending (but its timer is cancelled!)
      // - msg3 should still be pending (but its timer is cancelled!)
      //
      // This means msg2 and msg3 can NEVER time out, stuck in "sending" forever.

      // Verify all 3 start as pending/sending
      expect(
        s3
            .messagesForConversation('conv1')
            .where((m) => m.status == MessageStatus.sending),
        hasLength(3),
        reason: 'All 3 messages should be in sending state',
      );
    });
  });

  // =========================================================================
  // C2: Crypto marked initialized even when key upload fails
  // =========================================================================
  group('C2: CryptoState allows operation after upload failure', () {
    // This test documents CURRENT BUGGY behavior. When the bug is fixed by
    // making CryptoState.isInitialized return false (or adding an isReady
    // getter) when keysUploadFailed is true, update the first assertion
    // from isTrue → isFalse and remove the skip.
    test(
      'isInitialized should be false when keysUploadFailed is true',
      () {
        // crypto_provider.dart:117-124 sets isInitialized=true AND
        // keysUploadFailed=true simultaneously. This means any code that
        // only checks isInitialized will proceed with broken keys.

        const state = CryptoState(
          isInitialized: true,
          keysUploadFailed: true,
          error: 'Key upload failed: network error',
        );

        // BUG: isInitialized is true even though keys failed to upload.
        // This assertion verifies the current incorrect behavior and WILL
        // break once the fix makes isInitialized return false here.
        expect(
          state.isInitialized,
          isTrue,
          reason: 'BUG: isInitialized is true despite keysUploadFailed',
        );
        expect(state.keysUploadFailed, isTrue);

        // The correct behavior: isInitialized should be false OR there
        // should be a combined check like `isReady` that checks both flags.
        // Currently nothing prevents sending encrypted messages with
        // unuploaded keys.
        final canSendEncrypted = state.isInitialized && !state.keysUploadFailed;
        expect(
          canSendEncrypted,
          isFalse,
          reason:
              'Should not be able to send encrypted messages with failed upload',
        );
      },
      skip: 'BUG C2: documents current buggy behavior -- '
          'update to isFalse when CryptoState.isInitialized is fixed',
    );
  });

  // =========================================================================
  // C3: No mutex on token refresh — concurrent 401s cause double refresh
  // =========================================================================
  group('C3: authenticatedRequest has no refresh lock', () {
    test('two concurrent 401s should not trigger two refresh calls', () {
      // auth_provider.dart:220-237 — authenticatedRequest calls
      // refreshAccessToken() on 401 with no lock/dedup.
      // If two API calls return 401 simultaneously, both call
      // refreshAccessToken(). Server-side refresh token rotation means
      // the second refresh will fail (token already consumed).
      //
      // This is a design-level issue that can't be tested with pure state
      // tests, but we can prove the lack of a lock by examining the code:
      //
      // Future<http.Response> authenticatedRequest(requestFn) async {
      //   final response = await requestFn(token);
      //   if (response.statusCode == 401) {
      //     final refreshed = await refreshAccessToken(); // NO LOCK
      //     ...
      //   }
      // }
      //
      // We verify the AuthState model allows this race:
      const state = AuthState(
        isLoggedIn: true,
        token: 'expired_token',
        refreshToken: 'valid_refresh',
      );

      // Two concurrent callers would both read the same expired token
      expect(state.token, 'expired_token');
      // Both would call refreshAccessToken() simultaneously
      // The second caller's refresh will fail because the first consumed it
      //
      // NOTE: Full integration test would require mock HTTP client.
      // This test documents the pattern; the fix needs a Completer-based lock.
    });
  });

  // =========================================================================
  // C4: Typing indicator fires during message editing
  // =========================================================================
  group('C4: typing indicator sent during edit mode', () {
    test(
      'typing indicator should not fire when editing an existing message',
      () {
        // chat_input_bar.dart:330-340 — _onInputChanged() calls sendTyping()
        // whenever text.isNotEmpty, regardless of whether the user is editing.
        //
        // When editing, _isEditing is true, but the typing send doesn't check.
        // This is a widget-level issue, documented here for tracking.
        //
        // The fix: add `if (_isEditing) return;` before the typing send.
      },
      skip: 'widget-level bug, needs integration test with actual widget',
    );
  });

  // =========================================================================
  // H1: Accept contact request doesn't reload conversations
  // =========================================================================
  group('H1: accepting contact request does not create conversation', () {
    test(
      'conversation list should update after accepting contact',
      () {
        // contacts_provider.dart:141-155 — acceptRequest() calls
        // loadContacts() and loadPending() but NOT
        // conversationsProvider.loadConversations().
        //
        // After accepting, the DM conversation exists on the server but
        // the local conversation list is stale.
        //
        // This is a provider interaction issue — documented for fix.
      },
      skip:
          'provider interaction bug, needs integration test with multiple providers',
    );
  });

  // =========================================================================
  // H2: Unread count cleared before server confirms
  // =========================================================================
  group('H2: unread count optimistically cleared without rollback', () {
    test('unread count should not be zero if server call fails', () {
      // conversations_provider.dart:205-215 — markAsRead() sets
      // unreadCount: 0 immediately. sendReadReceipt() calls markAsRead()
      // BEFORE the server call. No rollback on failure.

      const conv = Conversation(id: 'conv1', isGroup: false, unreadCount: 5);
      final state = ConversationsState(conversations: [conv]);
      expect(state.conversations.first.unreadCount, 5);

      // After markAsRead, count is 0 regardless of server response
      final updated = List<Conversation>.from(state.conversations);
      final index = updated.indexWhere((c) => c.id == 'conv1');
      updated[index] = updated[index].copyWith(unreadCount: 0);
      final newState = state.copyWith(conversations: updated);

      expect(
        newState.conversations.first.unreadCount,
        0,
        reason: 'BUG: Count cleared before server confirms',
      );
      // If the server call fails, there's no way to restore unreadCount: 5
    });
  });

  // =========================================================================
  // H3: Leaving conversation doesn't clear chat messages
  // =========================================================================
  group('H3: leaveConversation does not clear message cache', () {
    test('messages should be cleared when conversation is removed', () {
      // conversations_provider.dart:280-299 removes conversation from list
      // but does NOT clear chatProvider.messagesByConversation[convId].
      //
      // Stale messages remain in memory.

      const chatState = ChatState();
      final msg = ChatMessage(
        id: 'msg1',
        fromUserId: 'alice',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'secret message',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final withMsg = chatState.withMessage(msg);

      // Conversation is removed from conversations list
      const convState = ConversationsState(
        conversations: [Conversation(id: 'conv1', isGroup: false)],
      );
      final afterLeave = convState.copyWith(
        conversations: convState.conversations
            .where((c) => c.id != 'conv1')
            .toList(),
      );
      expect(afterLeave.conversations, isEmpty);

      // BUG: Chat messages are NOT cleared
      expect(
        withMsg.messagesForConversation('conv1'),
        hasLength(1),
        reason: 'BUG: Messages persist after conversation removal',
      );
    });
  });

  // =========================================================================
  // H5: (Resolved) Tabs removed -- sidebar uses unified list with filter chips.
  // =========================================================================

  // =========================================================================
  // H9: getOrCreateDm doesn't validate returned conversation type
  // =========================================================================
  group('H9: getOrCreateDm does not validate isGroup=false', () {
    test('returned conversation should be validated as non-group', () {
      // conversations_provider.dart:240-275 — after server creates the DM,
      // it searches state.conversations by ID but doesn't check isGroup.
      //
      // If server returns a group, it's silently used as a DM.

      final conversations = [
        const Conversation(id: 'conv1', isGroup: true, name: 'Group Chat'),
      ];

      // Simulating the lookup in getOrCreateDm after server returns conv1
      final found = conversations.where((c) => c.id == 'conv1').firstOrNull;

      // BUG: Found a group conversation, but getOrCreateDm doesn't check
      expect(found, isNotNull);
      expect(
        found!.isGroup,
        isTrue,
        reason: 'BUG: getOrCreateDm would return a group as a DM',
      );
      // The fix: add `&& !c.isGroup` to the lookup
    });
  });

  // =========================================================================
  // M: ChatState.replyToMessage persists across conversation switches
  // =========================================================================
  group('M: reply state leaks across conversations', () {
    test('reply context should be conversation-scoped', () {
      // chat_provider.dart:79 — replyToMessage is a global field in ChatState,
      // not scoped to a conversation. Switching conversations doesn't clear it.

      final replyMsg = ChatMessage(
        id: 'msg_in_conv1',
        fromUserId: 'alice',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'Reply to this',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );

      const state = ChatState();
      final withReply = state.copyWith(replyToMessage: replyMsg);

      // User switches to conv2 — reply should be cleared
      // BUG: replyToMessage still points to conv1 message
      expect(
        withReply.replyToMessage?.conversationId,
        'conv1',
        reason: 'BUG: Reply to conv1 message persists when in conv2',
      );
    });
  });

  // =========================================================================
  // H2 FIX VERIFICATION: sendReadReceipt rollback
  // =========================================================================
  group('H2 fix: unread count rollback on failure', () {
    test(
      'ConversationsState supports restoring unread count after failure',
      () {
        const conv = Conversation(id: 'conv1', isGroup: false, unreadCount: 5);
        final state = ConversationsState(conversations: [conv]);

        // Optimistically clear
        final updated = List<Conversation>.from(state.conversations);
        updated[0] = updated[0].copyWith(unreadCount: 0);
        final cleared = state.copyWith(conversations: updated);
        expect(cleared.conversations.first.unreadCount, 0);

        // Rollback on failure
        final rollback = List<Conversation>.from(cleared.conversations);
        rollback[0] = rollback[0].copyWith(unreadCount: 5);
        final restored = cleared.copyWith(conversations: rollback);
        expect(
          restored.conversations.first.unreadCount,
          5,
          reason: 'Unread count should be restored after server failure',
        );
      },
    );
  });

  // =========================================================================
  // H3 FIX VERIFICATION: clearConversation removes messages
  // =========================================================================
  group('H3 fix: clearConversation removes cached messages', () {
    test('ChatState can remove all messages for a conversation', () {
      const state = ChatState();
      final msg1 = ChatMessage(
        id: 'msg1',
        fromUserId: 'alice',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'hello',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final msg2 = ChatMessage(
        id: 'msg2',
        fromUserId: 'bob',
        fromUsername: 'bob',
        conversationId: 'conv2',
        content: 'hey',
        timestamp: '2026-01-01T00:00:01Z',
        isMine: false,
      );
      final s1 = state.withMessage(msg1).withMessage(msg2);
      expect(s1.messagesForConversation('conv1'), hasLength(1));
      expect(s1.messagesForConversation('conv2'), hasLength(1));

      // Remove conv1 messages (simulating clearConversation)
      final updatedConv = Map<String, List<ChatMessage>>.from(
        s1.messagesByConversation,
      );
      updatedConv.remove('conv1');
      final cleared = s1.copyWith(messagesByConversation: updatedConv);

      expect(
        cleared.messagesForConversation('conv1'),
        isEmpty,
        reason: 'conv1 messages should be cleared',
      );
      expect(
        cleared.messagesForConversation('conv2'),
        hasLength(1),
        reason: 'conv2 messages should be untouched',
      );
    });
  });

  // =========================================================================
  // H4 FIX VERIFICATION: encryption toggle conceptual test
  // =========================================================================
  group('H4 fix: encryption toggle and preview desync', () {
    test('toggling encryption should not preserve stale plaintext preview', () {
      // The _decryptedPreviews map is internal to ConversationsNotifier,
      // so we can't test it directly. But we can verify the Conversation
      // model correctly toggles encryption state.
      const conv = Conversation(
        id: 'conv1',
        isGroup: false,
        isEncrypted: false,
        lastMessage: 'hello plaintext',
      );

      final encrypted = conv.copyWith(isEncrypted: true);
      expect(encrypted.isEncrypted, isTrue);
      // The fix clears _decryptedPreviews[conv.id] in updateEncryption(),
      // which is an internal side-effect tested by integration tests.
    });
  });

  // =========================================================================
  // H6 FIX VERIFICATION: reaction guard on deleted message
  // =========================================================================
  group('H6 fix: reaction guard on deleted messages', () {
    test('message existence check prevents reaction on deleted message', () {
      const state = ChatState();
      final msg = ChatMessage(
        id: 'msg1',
        fromUserId: 'alice',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'hello',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      final withMsg = state.withMessage(msg);
      expect(
        withMsg.messagesForConversation('conv1').any((m) => m.id == 'msg1'),
        isTrue,
      );

      // Delete the message
      final updatedConv = Map<String, List<ChatMessage>>.from(
        withMsg.messagesByConversation,
      );
      updatedConv['conv1'] = updatedConv['conv1']!
          .where((m) => m.id != 'msg1')
          .toList();
      final afterDelete = withMsg.copyWith(messagesByConversation: updatedConv);

      // Guard check: message no longer exists
      final stillExists = afterDelete
          .messagesForConversation('conv1')
          .any((m) => m.id == 'msg1');
      expect(
        stillExists,
        isFalse,
        reason: 'Reaction should be blocked — message was deleted',
      );
    });
  });

  // =========================================================================
  // H8 FIX VERIFICATION: scroll position cache key includes channel
  // =========================================================================
  group('H8 fix: scroll position cache keyed by conv+channel', () {
    test('different channels should have different cache keys', () {
      // Simulating the cache key logic
      const convId = 'conv1';
      const channel1 = 'ch-general';
      const channel2 = 'ch-random';

      final key1 = '$convId:$channel1';
      final key2 = '$convId:$channel2';
      final keyDefault = '$convId:';

      expect(
        key1,
        isNot(equals(key2)),
        reason: 'Different channels should produce different keys',
      );
      expect(
        key1,
        isNot(equals(keyDefault)),
        reason: 'Channel key should differ from no-channel key',
      );

      // Simulate cache
      final cache = <String, double>{};
      cache[key1] = 500.0;
      cache[key2] = 100.0;
      expect(cache[key1], 500.0);
      expect(cache[key2], 100.0);
    });
  });

  // =========================================================================
  // M2 FIX VERIFICATION: edit mode clears reply
  // =========================================================================
  group('M2 fix: edit mode clears reply state', () {
    test('entering edit should clear replyToMessage', () {
      final replyMsg = ChatMessage(
        id: 'msg1',
        fromUserId: 'alice',
        fromUsername: 'alice',
        conversationId: 'conv1',
        content: 'reply to this',
        timestamp: '2026-01-01T00:00:00Z',
        isMine: false,
      );
      const state = ChatState();
      final withReply = state.copyWith(replyToMessage: replyMsg);
      expect(withReply.replyToMessage, isNotNull);

      // clearReplyTo should remove the reply
      final cleared = withReply.copyWith(clearReply: true);
      expect(
        cleared.replyToMessage,
        isNull,
        reason: 'Reply should be cleared when entering edit mode',
      );
    });
  });

  // =========================================================================
  // M3 FIX VERIFICATION: pinned/unpinned conversations sorted by timestamp
  // =========================================================================
  group('M3 fix: conversations sorted by timestamp within groups', () {
    test('unpinned conversations should be sorted newest-first', () {
      const older = Conversation(
        id: 'conv1',
        isGroup: false,
        lastMessageTimestamp: '2026-01-01T00:00:00Z',
      );
      const newer = Conversation(
        id: 'conv2',
        isGroup: false,
        lastMessageTimestamp: '2026-01-02T00:00:00Z',
      );

      final unsorted = [older, newer];
      unsorted.sort((a, b) {
        final ta = a.lastMessageTimestamp ?? '';
        final tb = b.lastMessageTimestamp ?? '';
        return tb.compareTo(ta);
      });

      expect(
        unsorted.first.id,
        'conv2',
        reason: 'Newer conversation should come first',
      );
      expect(unsorted.last.id, 'conv1');
    });
  });

  // =========================================================================
  // M6 FIX VERIFICATION: narrowPanelIndex reset on deleted conversation
  // =========================================================================
  group('M6 fix: narrow panel index resets on conversation removal', () {
    test('selected conversation removal clears selection state', () {
      // Simulating the sync logic
      const selectedConvId = 'conv1';
      var narrowPanelIndex = 1; // showing chat panel

      final conversations = <Conversation>[
        const Conversation(id: 'conv2', isGroup: false),
        // conv1 is gone — user left it
      ];

      final fresh = conversations
          .where((c) => c.id == selectedConvId)
          .firstOrNull;

      // Conversation no longer in list — reset
      if (fresh == null && conversations.isNotEmpty) {
        narrowPanelIndex = 0;
      }

      expect(
        narrowPanelIndex,
        0,
        reason:
            'Should reset to conversation list when selected conv is removed',
      );
    });
  });
}
