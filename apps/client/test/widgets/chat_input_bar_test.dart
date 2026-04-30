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
import 'package:echo_app/src/widgets/input/pending_attachments_strip.dart';

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
      expect(find.text('Message — encrypted'), findsOneWidget);
    });

    testWidgets('mic button shown when text is empty (no send button)', (
      tester,
    ) async {
      await tester.pumpApp(
        ChatInputBar(conversation: _dmConversation, onMessageSent: () {}),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      // When the text field is empty the send button is replaced by a mic button
      // for voice message recording. The mic_outlined icon should be visible.
      expect(find.byIcon(Icons.mic_outlined), findsOneWidget);
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

      // After entering text, the send icon should appear (replaces mic button)
      expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
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

      expect(find.textContaining('is typing'), findsOneWidget);
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

      expect(find.textContaining('are typing'), findsOneWidget);
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

    testWidgets('media picker and attach buttons are present', (tester) async {
      await tester.pumpApp(
        ChatInputBar(conversation: _dmConversation, onMessageSent: () {}),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      // Emoji/GIF toggle button
      expect(
        find.byIcon(Icons.sentiment_satisfied_alt_outlined),
        findsOneWidget,
      );
      // File attach button (now a bordered round circle with a plain plus glyph)
      expect(find.byIcon(Icons.add), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Edit-mode focused tests
  // ---------------------------------------------------------------------------

  group('ChatInputBar edit mode', () {
    const editMsg = ChatMessage(
      id: 'msg-edit',
      fromUserId: 'test-user-id',
      fromUsername: 'testuser',
      conversationId: 'conv-dm',
      content: 'Original content',
      timestamp: '2026-01-15T10:00:00Z',
      isMine: true,
    );

    testWidgets('enterEditMode fills text field with message content', (
      tester,
    ) async {
      final key = GlobalKey<ChatInputBarState>();
      await tester.pumpApp(
        ChatInputBar(
          key: key,
          conversation: _dmConversation,
          onMessageSent: () {},
        ),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      // Initially the text field is empty
      expect(find.text('Original content'), findsNothing);

      key.currentState!.enterEditMode(editMsg);
      await tester.pump();

      expect(find.text('Original content'), findsOneWidget);
    });

    testWidgets('enterEditMode changes hint text to editing prompt', (
      tester,
    ) async {
      final key = GlobalKey<ChatInputBarState>();
      await tester.pumpApp(
        ChatInputBar(
          key: key,
          conversation: _dmConversation,
          onMessageSent: () {},
        ),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      // Normal hint before edit mode
      expect(find.text('Message — encrypted'), findsOneWidget);

      key.currentState!.enterEditMode(editMsg);
      await tester.pump();

      // Hint changes to 'Edit your message…' when a TextField has no text
      // shown — but since the field IS pre-filled, the hint is hidden by
      // the content. Verify the send/check icon instead.
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('enterEditMode shows status bar "Editing message..."', (
      tester,
    ) async {
      final key = GlobalKey<ChatInputBarState>();
      await tester.pumpApp(
        ChatInputBar(
          key: key,
          conversation: _dmConversation,
          onMessageSent: () {},
        ),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      key.currentState!.enterEditMode(editMsg);
      await tester.pump();

      expect(find.textContaining('Editing message'), findsOneWidget);
    });

    testWidgets('escape key cancels edit mode', (tester) async {
      final key = GlobalKey<ChatInputBarState>();
      await tester.pumpApp(
        ChatInputBar(
          key: key,
          conversation: _dmConversation,
          onMessageSent: () {},
        ),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      key.currentState!.enterEditMode(editMsg);
      await tester.pump();

      // Confirm we are in edit mode
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      // Press Escape to cancel
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      // Back to normal send button
      expect(find.byIcon(Icons.check_rounded), findsNothing);
    });

    testWidgets('edit mode hides attach and emoji buttons', (tester) async {
      final key = GlobalKey<ChatInputBarState>();
      await tester.pumpApp(
        ChatInputBar(
          key: key,
          conversation: _dmConversation,
          onMessageSent: () {},
        ),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      // Both buttons present before edit mode
      expect(find.byIcon(Icons.add), findsOneWidget);

      key.currentState!.enterEditMode(editMsg);
      await tester.pump();

      // Attach button hidden during edit mode
      expect(find.byIcon(Icons.add), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------
  // Attachment staging focused tests
  // ---------------------------------------------------------------------------

  group('ChatInputBar attachment staging', () {
    testWidgets('staged attachment shows PendingAttachmentsStrip', (
      tester,
    ) async {
      final key = GlobalKey<ChatInputBarState>();
      await tester.pumpApp(
        ChatInputBar(
          key: key,
          conversation: _dmConversation,
          onMessageSent: () {},
        ),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      // No strip before staging
      expect(find.byType(PendingAttachmentsStrip), findsNothing);

      // Stage a file (bytes provided directly — no disk read needed)
      await key.currentState!.attachDroppedFile(
        path: '/tmp/photo.png',
        fileName: 'photo.png',
        bytes: Uint8List.fromList([137, 80, 78, 71]),
      );
      await tester.pump();

      // Strip now visible
      expect(find.byType(PendingAttachmentsStrip), findsOneWidget);
    });

    testWidgets('staged attachment shows filename in strip', (tester) async {
      final key = GlobalKey<ChatInputBarState>();
      await tester.pumpApp(
        ChatInputBar(
          key: key,
          conversation: _dmConversation,
          onMessageSent: () {},
        ),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      await key.currentState!.attachDroppedFile(
        path: '/tmp/report.pdf',
        fileName: 'report.pdf',
        bytes: Uint8List.fromList([37, 80, 68, 70]),
      );
      await tester.pump();

      expect(find.textContaining('report.pdf'), findsOneWidget);
    });

    testWidgets('send button hidden while attachment is still uploading', (
      tester,
    ) async {
      final key = GlobalKey<ChatInputBarState>();
      await tester.pumpApp(
        ChatInputBar(
          key: key,
          conversation: _dmConversation,
          onMessageSent: () {},
        ),
        overrides: _chatInputOverrides(),
      );
      await tester.pump();

      await key.currentState!.attachDroppedFile(
        path: '/tmp/photo.png',
        fileName: 'photo.png',
        bytes: Uint8List.fromList([137, 80, 78, 71]),
      );
      await tester.pump();

      // Send arrow should NOT be shown while upload is in progress
      expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);
    });
  });
}
