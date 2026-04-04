import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/reaction.dart';
import 'package:echo_app/src/widgets/message_item.dart';

import '../helpers/pump_app.dart';

/// Factory helper to build a basic [ChatMessage] for tests.
ChatMessage _makeMessage({
  String id = 'msg-1',
  String fromUserId = 'user-other',
  String fromUsername = 'alice',
  String conversationId = 'conv-1',
  String content = 'Hello world',
  String timestamp = '2026-01-15T10:30:00Z',
  bool isMine = false,
  MessageStatus status = MessageStatus.sent,
  List<Reaction> reactions = const [],
  String? editedAt,
  bool isEncrypted = false,
  String? replyToContent,
  String? replyToUsername,
}) {
  return ChatMessage(
    id: id,
    fromUserId: fromUserId,
    fromUsername: fromUsername,
    conversationId: conversationId,
    content: content,
    timestamp: timestamp,
    isMine: isMine,
    status: status,
    reactions: reactions,
    editedAt: editedAt,
    isEncrypted: isEncrypted,
    replyToContent: replyToContent,
    replyToUsername: replyToUsername,
  );
}

void main() {
  group('MessageItem', () {
    testWidgets('renders text message content', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: 'Hello from Alice');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        expect(find.text('Hello from Alice'), findsOneWidget);
      });
    });

    testWidgets('shows sender username when showHeader is true', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(fromUsername: 'bob');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: false,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        expect(find.text('bob'), findsOneWidget);
      });
    });

    testWidgets('hides sender username when showHeader is false', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(fromUsername: 'carol');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: false,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        // The username should not appear as a header text
        // (it may still appear in avatar, but not as a standalone Text widget
        // in the header position)
        final headerTexts = tester.widgetList<Text>(find.text('carol'));
        expect(headerTexts, isEmpty);
      });
    });

    testWidgets('shows timestamp when isLastInGroup is true', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(
          timestamp: '2026-01-15T14:30:00Z',
          isMine: true,
        );
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        // The timestamp area should be visible. The exact format depends on
        // formatMessageTimestamp, but there should be a small text showing time.
        // We just verify the timestamp row exists via the check icon (sent status).
        expect(find.byIcon(Icons.check_outlined), findsOneWidget);
      });
    });

    testWidgets('shows lock icon for encrypted messages', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(isEncrypted: true);
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        expect(find.byIcon(Icons.lock), findsOneWidget);
      });
    });

    testWidgets('shows "(edited)" for edited messages', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(editedAt: '2026-01-15T15:00:00Z');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        expect(find.text('(edited)'), findsOneWidget);
      });
    });

    testWidgets('renders reaction pill when reactions exist', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(
          reactions: [
            const Reaction(
              messageId: 'msg-1',
              userId: 'u1',
              username: 'alice',
              emoji: '\u{1F44D}',
            ),
            const Reaction(
              messageId: 'msg-1',
              userId: 'u2',
              username: 'bob',
              emoji: '\u{1F44D}',
            ),
          ],
        );
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: false,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        // The reaction emoji should be visible
        expect(find.text('\u{1F44D}'), findsOneWidget);
        // Count should show "2"
        expect(find.text('2'), findsOneWidget);
      });
    });

    testWidgets('shows error icon for failed message status', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(isMine: true, status: MessageStatus.failed);
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        expect(find.byIcon(Icons.error_outline), findsOneWidget);
      });
    });

    testWidgets('shows schedule icon for sending status', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(isMine: true, status: MessageStatus.sending);
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        expect(find.byIcon(Icons.schedule_outlined), findsOneWidget);
      });
    });

    testWidgets('shows done_all icon for delivered status', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(isMine: true, status: MessageStatus.delivered);
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        expect(find.byIcon(Icons.done_all_outlined), findsOneWidget);
      });
    });

    testWidgets('reply quote block renders when replyToContent set', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(
          replyToContent: 'Original message',
          replyToUsername: 'bob',
        );
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        expect(find.text('Original message'), findsOneWidget);
        expect(find.text('bob'), findsAtLeast(1));
      });
    });

    testWidgets('image marker renders image widget instead of text', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: '[img:/api/media/test.png]');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
            serverUrl: 'http://localhost:8080',
          ),
        );
        await tester.pump();

        // Should not render raw text
        expect(find.text('[img:/api/media/test.png]'), findsNothing);
        // Should show the expand icon overlay
        expect(find.byIcon(Icons.open_in_full), findsOneWidget);
      });
    });

    testWidgets('file marker renders file attachment card', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: '[file:/api/media/doc.pdf]');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
            serverUrl: 'http://localhost:8080',
          ),
        );
        await tester.pump();

        expect(find.text('[file:/api/media/doc.pdf]'), findsNothing);
        expect(find.text('doc.pdf'), findsOneWidget);
        expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
      });
    });

    testWidgets('video marker renders video card with play button', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: '[video:/api/media/clip.mp4]');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
            serverUrl: 'http://localhost:8080',
          ),
        );
        await tester.pump();

        expect(find.text('[video:/api/media/clip.mp4]'), findsNothing);
        expect(find.text('Video attachment'), findsOneWidget);
        expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
      });
    });

    testWidgets('direct image URL renders embedded image widget', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: 'https://example.com/image.png');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        expect(find.text('https://example.com/image.png'), findsNothing);
        expect(find.byIcon(Icons.open_in_full), findsOneWidget);
      });
    });

    testWidgets('direct GIF URL renders embedded media widget', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: 'https://example.com/fun.gif');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        expect(find.text('https://example.com/fun.gif'), findsNothing);
        expect(find.byIcon(Icons.open_in_full), findsOneWidget);
      });
    });

    testWidgets('my message does not render avatar column', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(isMine: true, fromUserId: 'test-user-id');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        // "isMine" messages are right-aligned and do not show sender name
        expect(find.text('alice'), findsNothing);
      });
    });

    testWidgets('onReactionSelect callback fires on long press', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        ChatMessage? tappedMessage;
        final msg = _makeMessage();

        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: false,
            myUserId: 'test-user-id',
            onReactionTap: (m, _) => tappedMessage = m,
          ),
        );
        await tester.pump();

        // Long press to trigger reaction tap
        await tester.longPress(find.text('Hello world'));
        await tester.pump();

        expect(tappedMessage, isNotNull);
        expect(tappedMessage!.id, 'msg-1');
      });
    });
  });
}
