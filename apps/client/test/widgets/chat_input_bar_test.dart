import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/voice_settings_provider.dart';
import 'package:echo_app/src/services/crypto_service.dart';
import 'package:echo_app/src/services/group_crypto_service.dart';
import 'package:echo_app/src/widgets/chat_input_bar.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

/// Override [chatProvider] with a specific [ChatState].
Override chatOverride([ChatState state = const ChatState()]) {
  return chatProvider.overrideWith((ref) => _FakeChatNotifier(ref, state));
}

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

/// Override [voiceSettingsProvider] with default state.
Override voiceSettingsOverride() {
  return voiceSettingsProvider.overrideWith(
    (ref) => _FakeVoiceSettingsNotifier(),
  );
}

class _FakeVoiceSettingsNotifier extends VoiceSettingsNotifier {
  _FakeVoiceSettingsNotifier() {
    state = const VoiceSettingsState();
  }
}

/// Standard overrides for ChatInputBar tests.
List<Override> _chatInputOverrides({ChatState chatState = const ChatState()}) {
  return [
    ...standardOverrides(),
    chatOverride(chatState),
    voiceSettingsOverride(),
  ];
}

/// A 1:1 DM conversation that is encrypted (sending is allowed).
const _dmConversation = Conversation(
  id: 'conv-dm',
  isGroup: false,
  isEncrypted: true,
  members: [
    ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ConversationMember(userId: 'user-alice', username: 'alice'),
  ],
);

/// A group conversation for mention testing.
const _groupConversation = Conversation(
  id: 'conv-group',
  name: 'Dev Team',
  isGroup: true,
  members: [
    ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ConversationMember(userId: 'user-alice', username: 'alice'),
    ConversationMember(userId: 'user-bob', username: 'bob'),
    ConversationMember(userId: 'user-carol', username: 'carol'),
  ],
);

void main() {
  group('ChatInputBar', () {
    testWidgets('renders text field with hint', (tester) async {
      await tester.pumpApp(
        ChatInputBar(conversation: _dmConversation, onMessageSent: () {}),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Type a message...'), findsOneWidget);
    });

    testWidgets('send button is visually disabled when text is empty', (
      tester,
    ) async {
      await tester.pumpApp(
        ChatInputBar(conversation: _dmConversation, onMessageSent: () {}),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      // The send button is an Opacity widget. When the text field is empty,
      // the send button should have reduced opacity (0.45).
      final opacityWidgets = tester
          .widgetList<Opacity>(find.byType(Opacity))
          .where((o) => o.opacity < 1.0)
          .toList();
      expect(opacityWidgets, isNotEmpty);
    });

    testWidgets('send button becomes active when text is entered', (
      tester,
    ) async {
      await tester.pumpApp(
        ChatInputBar(conversation: _dmConversation, onMessageSent: () {}),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Hello world');
      await tester.pump();

      // After entering text, the Opacity of the send button should be 1.0
      final sendButtonOpacity = tester
          .widgetList<Opacity>(find.byType(Opacity))
          .where((o) => o.opacity == 1.0)
          .toList();
      expect(sendButtonOpacity, isNotEmpty);
    });

    testWidgets('reply preview shows when reply is active', (tester) async {
      final replyMsg = ChatMessage(
        id: 'msg-reply',
        fromUserId: 'user-alice',
        fromUsername: 'alice',
        conversationId: 'conv-dm',
        content: 'Hey, what do you think?',
        timestamp: '2026-01-15T10:00:00Z',
        isMine: false,
      );
      final chatState = ChatState(replyToMessage: replyMsg);

      await tester.pumpApp(
        ChatInputBar(conversation: _dmConversation, onMessageSent: () {}),
        overrides: _chatInputOverrides(chatState: chatState),
      );
      await tester.pump();

      expect(find.text('Replying to alice'), findsOneWidget);
      expect(find.text('Hey, what do you think?'), findsOneWidget);
      expect(find.byIcon(Icons.reply_outlined), findsOneWidget);
    });

    testWidgets('reply preview has close button', (tester) async {
      final replyMsg = ChatMessage(
        id: 'msg-reply',
        fromUserId: 'user-alice',
        fromUsername: 'alice',
        conversationId: 'conv-dm',
        content: 'Some message',
        timestamp: '2026-01-15T10:00:00Z',
        isMine: false,
      );
      final chatState = ChatState(replyToMessage: replyMsg);

      await tester.pumpApp(
        ChatInputBar(conversation: _dmConversation, onMessageSent: () {}),
        overrides: _chatInputOverrides(chatState: chatState),
      );
      await tester.pump();

      // Close icon exists in the reply bar
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('typing indicator shows when typingUsers is non-empty', (
      tester,
    ) async {
      await tester.pumpApp(
        ChatInputBar(
          conversation: _dmConversation,
          typingUsers: const ['alice'],
          onMessageSent: () {},
        ),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      expect(find.textContaining('is typing...'), findsOneWidget);
    });

    testWidgets('group typing indicator shows multiple users', (tester) async {
      await tester.pumpApp(
        ChatInputBar(
          conversation: _groupConversation,
          typingUsers: const ['alice', 'bob'],
          onMessageSent: () {},
        ),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      expect(find.textContaining('are typing...'), findsOneWidget);
    });

    testWidgets('escape key clears reply when reply is active', (tester) async {
      final replyMsg = ChatMessage(
        id: 'msg-reply',
        fromUserId: 'user-alice',
        fromUsername: 'alice',
        conversationId: 'conv-dm',
        content: 'Some message to reply to',
        timestamp: '2026-01-15T10:00:00Z',
        isMine: false,
      );
      final chatState = ChatState(replyToMessage: replyMsg);

      await tester.pumpApp(
        ChatInputBar(conversation: _dmConversation, onMessageSent: () {}),
        overrides: _chatInputOverrides(chatState: chatState),
      );
      await tester.pump();

      // Verify reply preview is shown
      expect(find.text('Replying to alice'), findsOneWidget);

      // Focus the text field and press Escape
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      // After Escape, the reply should be cleared
      expect(find.text('Replying to alice'), findsNothing);
    });

    testWidgets('plus menu button is present', (tester) async {
      await tester.pumpApp(
        ChatInputBar(conversation: _dmConversation, onMessageSent: () {}),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
    });
  });
}
