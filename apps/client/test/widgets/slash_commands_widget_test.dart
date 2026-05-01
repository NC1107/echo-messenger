import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/services/slash_commands.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/voice_settings_provider.dart';
import 'package:echo_app/src/services/crypto_service.dart';
import 'package:echo_app/src/services/group_crypto_service.dart';
import 'package:echo_app/src/widgets/chat_input_bar.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

Override _chatOverride([ChatState state = const ChatState()]) {
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

Override _voiceSettingsOverride() {
  return voiceSettingsProvider.overrideWith(
    (ref) => _FakeVoiceSettingsNotifier(),
  );
}

class _FakeVoiceSettingsNotifier extends VoiceSettingsNotifier {
  _FakeVoiceSettingsNotifier() {
    state = const VoiceSettingsState();
  }
}

List<Override> _overrides() => [
  ...standardOverrides(),
  _chatOverride(),
  _voiceSettingsOverride(),
];

// ---------------------------------------------------------------------------
// Conversations
// ---------------------------------------------------------------------------

/// A group where 'test-user-id' is admin.
const _adminGroupConversation = Conversation(
  id: 'conv-group-admin',
  name: 'Admins Group',
  isGroup: true,
  members: [
    ConversationMember(
      userId: 'test-user-id',
      username: 'testuser',
      role: 'admin',
    ),
    ConversationMember(userId: 'user-alice', username: 'alice', role: 'member'),
  ],
);

/// A group where 'test-user-id' is a regular member.
const _memberGroupConversation = Conversation(
  id: 'conv-group-member',
  name: 'Regular Group',
  isGroup: true,
  members: [
    ConversationMember(
      userId: 'test-user-id',
      username: 'testuser',
      role: 'member',
    ),
    ConversationMember(userId: 'user-alice', username: 'alice', role: 'admin'),
  ],
);

// ---------------------------------------------------------------------------
// Helper widget that triggers a slash command on button press
// ---------------------------------------------------------------------------

/// Small widget that calls [dispatchSlashCommand] on a button tap so widget
/// tests can exercise the help dialog without needing the full ChatInputBar
/// send flow.
class _SlashTestHost extends ConsumerWidget {
  const _SlashTestHost({required this.cmd, required this.conversation});

  final SlashCommand cmd;
  final Conversation conversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ElevatedButton(
      onPressed: () => dispatchSlashCommand(cmd, conversation, ref, context),
      child: const Text('trigger'),
    );
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Slash commands — /help dialog', () {
    testWidgets('/help shows the help dialog', (tester) async {
      await tester.pumpApp(
        const _SlashTestHost(
          cmd: SlashCommand(name: 'help', args: ''),
          conversation: _adminGroupConversation,
        ),
        overrides: _overrides(),
      );

      await tester.tap(find.text('trigger'));
      await tester.pump(); // let showDialog push the route
      await tester.pump(); // render the dialog content

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Slash Commands'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Close'), findsOneWidget);
    });

    testWidgets('/help shows admin commands when user is admin', (
      tester,
    ) async {
      await tester.pumpApp(
        const _SlashTestHost(
          cmd: SlashCommand(name: 'help', args: ''),
          conversation: _adminGroupConversation,
        ),
        overrides: _overrides(),
      );

      await tester.tap(find.text('trigger'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Admin commands'), findsOneWidget);
      expect(find.textContaining('/name'), findsWidgets);
      expect(find.textContaining('/kick'), findsWidgets);
    });

    testWidgets('/help hides admin commands for non-admin members', (
      tester,
    ) async {
      await tester.pumpApp(
        const _SlashTestHost(
          cmd: SlashCommand(name: 'help', args: ''),
          conversation: _memberGroupConversation,
        ),
        overrides: _overrides(),
      );

      await tester.tap(find.text('trigger'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Admin commands'), findsNothing);
      expect(find.text('Everyone'), findsOneWidget);
    });

    testWidgets('closing the help dialog dismisses it', (tester) async {
      await tester.pumpApp(
        const _SlashTestHost(
          cmd: SlashCommand(name: 'help', args: ''),
          conversation: _adminGroupConversation,
        ),
        overrides: _overrides(),
      );

      await tester.tap(find.text('trigger'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('Slash commands — ChatInputBar integration', () {
    testWidgets(
      'typing /help and submitting does not send as regular message',
      (tester) async {
        var messagesSent = 0;
        await tester.pumpApp(
          ChatInputBar(
            conversation: _adminGroupConversation,
            onMessageSent: () => messagesSent++,
          ),
          overrides: _overrides(),
        );
        await tester.pump();

        await tester.enterText(find.byType(TextField), '/help');
        await tester.pump();

        // Send button should be visible (text is non-empty).
        expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);

        await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
        await tester.pump();
        await tester.pump();

        // onMessageSent must NOT be called for a handled slash command.
        expect(messagesSent, 0);

        // Text field should be cleared after handling.
        final tf = tester.widget<TextField>(find.byType(TextField));
        expect(tf.controller?.text ?? '', isEmpty);
      },
    );
  });
}
