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
    themeProvider.overrideWith((ref) => _FakeThemeNotifier()),
    messageLayoutProvider.overrideWith((ref) => _FakeMessageLayoutNotifier()),
  ];
}

class _FakeThemeNotifier extends ThemeNotifier {
  _FakeThemeNotifier() {
    state = AppThemeSelection.dark;
  }
}

class _FakeMessageLayoutNotifier extends MessageLayoutNotifier {
  _FakeMessageLayoutNotifier() {
    state = MessageLayout.bubbles;
  }
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

      expect(find.text('Select a conversation'), findsOneWidget);
      expect(
        find.text('Pick someone from the left to start chatting'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
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
      final chatState = ChatState(loadingHistory: {'conv-dm': true});

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
      expect(find.text('Type a message...'), findsOneWidget);
    });

    testWidgets('placeholder is not shown when conversation is provided', (
      tester,
    ) async {
      await tester.pumpApp(
        ChatPanel(conversation: _dmConversation),
        overrides: _chatPanelOverrides(),
      );
      await tester.pump();

      // The "Select a conversation" placeholder should NOT be shown
      expect(find.text('Select a conversation'), findsNothing);
    });
  });
}
