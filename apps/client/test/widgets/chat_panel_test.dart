import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/channels_provider.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/privacy_provider.dart';
import 'package:echo_app/src/providers/theme_provider.dart';
import 'package:echo_app/src/providers/livekit_voice_provider.dart';
import 'package:echo_app/src/providers/voice_settings_provider.dart';
import 'package:echo_app/src/services/crypto_service.dart';
import 'package:echo_app/src/services/group_crypto_service.dart';
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/chat_panel.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

// ---------------------------------------------------------------------------
// Fake notifiers for additional providers ChatPanel depends on
// ---------------------------------------------------------------------------

class _FakeChatNotifier extends ChatNotifier {
  _FakeChatNotifier(super.ref, ChatState initial) {
    state = initial;
  }

  @override
  Future<void> loadHistoryWithUserId(
    String conversationId,
    String token,
    String userId, {
    String? channelId,
    String? before,
    CryptoService? crypto,
    GroupCryptoService? groupCrypto,
    bool isGroup = false,
  }) async {}

  @override
  void clearReplyTo() {
    state = state.copyWith(clearReply: true);
  }
}

class _FakeChannelsNotifier extends ChannelsNotifier {
  _FakeChannelsNotifier(super.ref) {
    state = const ChannelsState();
  }

  @override
  Future<void> loadChannels(String conversationId) async {}
}

class _FakePrivacyNotifier extends PrivacyNotifier {
  _FakePrivacyNotifier(super.ref) {
    state = const PrivacyState();
  }
}

class _FakeVoiceSettingsNotifier extends VoiceSettingsNotifier {
  _FakeVoiceSettingsNotifier() {
    state = const VoiceSettingsState();
  }
}

class _FakeVoiceRtcNotifier extends LiveKitVoiceNotifier {
  _FakeVoiceRtcNotifier(super.ref);
}

/// Builds the full set of overrides needed for ChatPanel widget tests.
List<Override> _chatPanelOverrides({ChatState chatState = const ChatState()}) {
  return [
    ...standardOverrides(),
    chatProvider.overrideWith((ref) => _FakeChatNotifier(ref, chatState)),
    channelsProvider.overrideWith((ref) => _FakeChannelsNotifier(ref)),
    privacyProvider.overrideWith((ref) => _FakePrivacyNotifier(ref)),
    voiceSettingsProvider.overrideWith((ref) => _FakeVoiceSettingsNotifier()),
    voiceRtcProvider.overrideWith((ref) => _FakeVoiceRtcNotifier(ref)),
    appThemeProvider.overrideWith(_FakeTheme.new),
    messageLayoutNotifierProvider.overrideWith(_FakeMessageLayoutNotifier.new),
  ];
}

/// `@riverpod` Notifier fakes override `build()` instead of mutating
/// `state` from a constructor -- the generated parent class initialises
/// `state` from the value `build()` returns.
class _FakeTheme extends AppTheme {
  @override
  AppThemeSelection build() => AppThemeSelection.dark;
}

class _FakeMessageLayoutNotifier extends MessageLayoutNotifier {
  @override
  MessageLayout build() => MessageLayout.bubbles;
}

/// A 1:1 DM conversation.
const _dmConversation = Conversation(
  id: 'conv-dm',
  isGroup: false,
  isEncrypted: true,
  members: [
    ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ConversationMember(userId: 'user-alice', username: 'alice'),
  ],
);

/// A group conversation.
const _groupConversation = Conversation(
  id: 'conv-group',
  name: 'Dev Team',
  isGroup: true,
  members: [
    ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ConversationMember(userId: 'user-alice', username: 'alice'),
    ConversationMember(userId: 'user-bob', username: 'bob'),
  ],
);

void main() {
  group('ChatPanel', () {
    testWidgets('empty state placeholder renders when no conversation', (
      tester,
    ) async {
      await tester.pumpApp(
        const ChatPanel(conversation: null),
        overrides: _chatPanelOverrides(),
      );
      await tester.pump();

      expect(find.text('No conversation selected'), findsOneWidget);
      expect(
        find.text('Choose a conversation from the sidebar or start a new one'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.forum_rounded), findsOneWidget);
    });

    testWidgets('shows peer name in DM conversation header area', (
      tester,
    ) async {
      await tester.pumpApp(
        ChatPanel(conversation: _dmConversation),
        overrides: _chatPanelOverrides(),
      );
      await tester.pump();

      // The header bar should show the peer's name
      expect(find.text('alice'), findsWidgets);
    });

    testWidgets('shows group name in group conversation', (tester) async {
      await tester.pumpApp(
        ChatPanel(conversation: _groupConversation),
        overrides: _chatPanelOverrides(),
      );
      await tester.pump();

      expect(find.text('Dev Team'), findsWidgets);
    });

    testWidgets('empty message placeholder renders with no messages', (
      tester,
    ) async {
      await tester.pumpApp(
        ChatPanel(conversation: _dmConversation),
        overrides: _chatPanelOverrides(),
      );
      await tester.pump();

      // The empty message placeholder shows "Start your conversation with alice"
      expect(
        find.textContaining('Start your conversation with'),
        findsOneWidget,
      );
    });

    testWidgets('message list renders with messages', (tester) async {
      final messages = [
        ChatMessage(
          id: 'msg-1',
          fromUserId: 'user-alice',
          fromUsername: 'alice',
          conversationId: 'conv-dm',
          content: 'Hello there!',
          timestamp: '2026-01-15T10:00:00Z',
          isMine: false,
        ),
        ChatMessage(
          id: 'msg-2',
          fromUserId: 'test-user-id',
          fromUsername: 'testuser',
          conversationId: 'conv-dm',
          content: 'Hi alice!',
          timestamp: '2026-01-15T10:01:00Z',
          isMine: true,
        ),
      ];

      final chatState = ChatState(
        messagesByConversation: {'conv-dm': messages},
      );

      await tester.pumpApp(
        ChatPanel(conversation: _dmConversation),
        overrides: _chatPanelOverrides(chatState: chatState),
      );
      await tester.pump();

      expect(find.text('Hello there!'), findsOneWidget);
      expect(find.text('Hi alice!'), findsOneWidget);
    });

    testWidgets('loading indicator shows when loading history', (tester) async {
      final chatState = ChatState(loadingHistory: {'conv-dm:': true});

      await tester.pumpApp(
        ChatPanel(conversation: _dmConversation),
        overrides: _chatPanelOverrides(chatState: chatState),
      );
      await tester.pump();

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('no loading indicator when not loading history', (
      tester,
    ) async {
      await tester.pumpApp(
        ChatPanel(conversation: _dmConversation),
        overrides: _chatPanelOverrides(),
      );
      await tester.pump();

      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('chat input bar is present in conversation view', (
      tester,
    ) async {
      await tester.pumpApp(
        ChatPanel(conversation: _dmConversation),
        overrides: _chatPanelOverrides(),
      );
      await tester.pump();

      // The ChatInputBar contains a TextField
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Message — encrypted'), findsOneWidget);
    });

    testWidgets('placeholder is not shown when conversation is provided', (
      tester,
    ) async {
      await tester.pumpApp(
        ChatPanel(conversation: _dmConversation),
        overrides: _chatPanelOverrides(),
      );
      await tester.pump();

      // The "No conversation selected" placeholder should NOT be shown
      expect(find.text('No conversation selected'), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------
  // State mutation tests: delete, pin, rollback
  // ---------------------------------------------------------------------------

  /// Pumps [ChatPanel] using an [UncontrolledProviderScope] so tests can
  /// mutate the [ProviderContainer] directly and observe widget reactions.
  Future<ProviderContainer> pumpWithContainer(
    WidgetTester tester, {
    required ChatState chatState,
  }) async {
    final container = ProviderContainer(
      overrides: _chatPanelOverrides(chatState: chatState),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: EchoTheme.darkTheme,
          darkTheme: EchoTheme.darkTheme,
          themeMode: ThemeMode.dark,
          home: const Scaffold(body: ChatPanel(conversation: _dmConversation)),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  group('ChatPanel mutation – delete', () {
    const testMsg = ChatMessage(
      id: 'msg-del',
      fromUserId: 'user-alice',
      fromUsername: 'alice',
      conversationId: 'conv-dm',
      content: 'Delete me please',
      timestamp: '2026-01-15T10:00:00Z',
      isMine: false,
    );

    // skipped: #670 — state-mutation propagation in widget tests
    testWidgets('optimistic delete removes message from list', skip: true, (
      tester,
    ) async {
      final chatState = ChatState(
        messagesByConversation: {
          'conv-dm': [testMsg],
        },
      );

      final container = await pumpWithContainer(tester, chatState: chatState);
      expect(find.text('Delete me please'), findsOneWidget);

      container.read(chatProvider.notifier).deleteMessage('conv-dm', 'msg-del');
      await tester.pump();

      expect(find.text('Delete me please'), findsNothing);
    });

    // skipped: #670 — state-mutation propagation in widget tests
    testWidgets('rollback restores message after failed delete', skip: true, (
      tester,
    ) async {
      final chatState = ChatState(
        messagesByConversation: {
          'conv-dm': [testMsg],
        },
      );

      final container = await pumpWithContainer(tester, chatState: chatState);
      expect(find.text('Delete me please'), findsOneWidget);

      // Simulate optimistic remove then rollback (server rejected the delete)
      container.read(chatProvider.notifier).deleteMessage('conv-dm', 'msg-del');
      await tester.pump();
      expect(find.text('Delete me please'), findsNothing);

      container.read(chatProvider.notifier).addMessage(testMsg);
      await tester.pump();

      expect(find.text('Delete me please'), findsOneWidget);
    });
  });

  group('ChatPanel mutation – pin', () {
    const testMsg = ChatMessage(
      id: 'msg-pin',
      fromUserId: 'user-alice',
      fromUsername: 'alice',
      conversationId: 'conv-dm',
      content: 'Pin this message',
      timestamp: '2026-01-15T10:00:00Z',
      isMine: false,
    );

    // skipped: #670 — state-mutation propagation in widget tests
    testWidgets('optimistic pin update is reflected in state', skip: true, (
      tester,
    ) async {
      final chatState = ChatState(
        messagesByConversation: {
          'conv-dm': [testMsg],
        },
      );

      final container = await pumpWithContainer(tester, chatState: chatState);

      // Before pin – pinnedById is null
      final before = container
          .read(chatProvider)
          .messagesForConversation('conv-dm')
          .first;
      expect(before.pinnedById, isNull);

      // Optimistically pin the message
      final pinTime = DateTime.parse('2026-03-01T12:00:00Z');
      container
          .read(chatProvider.notifier)
          .updateMessagePin('conv-dm', 'msg-pin', 'test-user-id', pinTime);
      await tester.pump();

      final after = container
          .read(chatProvider)
          .messagesForConversation('conv-dm')
          .first;
      expect(after.pinnedById, 'test-user-id');
      expect(after.pinnedAt, pinTime);
    });

    // skipped: #670 — state-mutation propagation in widget tests
    testWidgets('rollback clears pin on server failure', skip: true, (
      tester,
    ) async {
      final chatState = ChatState(
        messagesByConversation: {
          'conv-dm': [testMsg],
        },
      );

      final container = await pumpWithContainer(tester, chatState: chatState);

      // Optimistically pin
      container
          .read(chatProvider.notifier)
          .updateMessagePin(
            'conv-dm',
            'msg-pin',
            'test-user-id',
            DateTime.now(),
          );
      await tester.pump();

      // Server rejected → revert
      container
          .read(chatProvider.notifier)
          .updateMessagePin('conv-dm', 'msg-pin', null, null);
      await tester.pump();

      final reverted = container
          .read(chatProvider)
          .messagesForConversation('conv-dm')
          .first;
      expect(reverted.pinnedById, isNull);
      expect(reverted.pinnedAt, isNull);
    });
  });

  group('ChatPanel loading states', () {
    testWidgets('history-key with channel suffix is respected', (tester) async {
      // Key format is '$conversationId:$channelId' — for a DM with no
      // channel the suffix is empty, so the correct key is 'conv-dm:'.
      final chatState = ChatState(loadingHistory: {'conv-dm:': true});

      await tester.pumpApp(
        ChatPanel(conversation: _dmConversation),
        overrides: _chatPanelOverrides(chatState: chatState),
      );
      await tester.pump();

      // The LinearProgressIndicator must be visible when loading.
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('skeleton loader shown when loading with no messages', (
      tester,
    ) async {
      final chatState = ChatState(loadingHistory: {'conv-dm:': true});

      await tester.pumpApp(
        ChatPanel(conversation: _dmConversation),
        overrides: _chatPanelOverrides(chatState: chatState),
      );
      await tester.pump();

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // Empty-state placeholder should NOT appear while loading
      expect(find.textContaining('Start your conversation'), findsNothing);
    });
  });
}
