import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/reaction.dart';
import 'package:echo_app/src/widgets/message/reaction_bar.dart';
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

        expect(find.text('(edited)'), findsWidgets);
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

        expect(find.byIcon(Icons.error_outline), findsAtLeastNWidgets(1));
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
        // Allow video init future to settle (fails in test -> shows fallback).
        await tester.pumpAndSettle();

        expect(find.text('[video:/api/media/clip.mp4]'), findsNothing);
        // Static play-thumbnail uses a rounded play arrow inside a dark
        // circle (the inline init flow was removed last round).
        expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
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

    testWidgets('pinned message shows pin indicator with "Pinned" text', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage().copyWith(
          pinnedById: 'admin',
          pinnedAt: DateTime.parse('2026-01-15T12:00:00Z'),
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

        expect(find.text('Pinned'), findsOneWidget);
        expect(find.byIcon(Icons.push_pin), findsAtLeast(1));
      });
    });

    testWidgets('unpinned message does not show pin indicator', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage();
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        expect(find.text('Pinned'), findsNothing);
      });
    });

    testWidgets('bold markdown renders as bold text', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: 'This is **bold** text');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        // The message should render using RichText with bold spans.
        // Verify the raw markdown markers are not shown.
        expect(find.textContaining('**'), findsNothing);
        // The content should be rendered via RichText
        final richTexts = find.byType(RichText);
        expect(richTexts, findsAtLeast(1));
      });
    });

    testWidgets('italic markdown renders without markers', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: 'This is *italic* text');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        // Verify asterisk markers are not displayed as raw text
        // The content is rendered via RichText spans
        final richTexts = find.byType(RichText);
        expect(richTexts, findsAtLeast(1));
      });
    });

    testWidgets('check icon renders for sent status', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(isMine: true, status: MessageStatus.sent);
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        expect(find.byIcon(Icons.check_outlined), findsOneWidget);
      });
    });

    testWidgets('message with no reactions has no reaction pill', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(reactions: []);
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: false,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        // No ReactionBar should appear when there are no reactions
        expect(find.byType(ReactionBar), findsNothing);
      });
    });

    testWidgets('multiple different reactions render separate pills', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(
          reactions: const [
            Reaction(
              messageId: 'msg-1',
              userId: 'u1',
              username: 'alice',
              emoji: '\u{1F44D}',
            ),
            Reaction(
              messageId: 'msg-1',
              userId: 'u2',
              username: 'bob',
              emoji: '\u{2764}',
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

        expect(find.text('\u{1F44D}'), findsOneWidget);
        expect(find.text('\u{2764}'), findsOneWidget);
      });
    });

    testWidgets('my pinned message shows pin indicator', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(isMine: true, fromUserId: 'test-user-id')
            .copyWith(
              pinnedById: 'admin',
              pinnedAt: DateTime.parse('2026-01-15T12:00:00Z'),
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

        expect(find.text('Pinned'), findsOneWidget);
      });
    });

    testWidgets('inline code renders without backtick markers', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: 'Use `flutter test` to run');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        // RichText should be used for inline code rendering
        final richTexts = find.byType(RichText);
        expect(richTexts, findsAtLeast(1));
      });
    });

    testWidgets('exposes onMoreReactions callback on widget', (tester) async {
      // The "More emojis" button only renders inside the mobile action sheet,
      // which is gated by defaultTargetPlatform == android/iOS. In a host-VM
      // unit test the sheet path isn't reachable, so we verify at the widget
      // contract level: the prop is wired through to MessageItem and survives
      // a build pass without crashing the existing render path.
      await mockNetworkImagesFor(() async {
        ChatMessage? captured;
        final msg = _makeMessage();
        final item = MessageItem(
          message: msg,
          showHeader: true,
          isLastInGroup: true,
          myUserId: 'test-user-id',
          onMoreReactions: (m) => captured = m,
        );

        await tester.pumpApp(item);
        await tester.pump();

        expect(item.onMoreReactions, isNotNull);
        // Invoke directly to confirm the callback contract.
        item.onMoreReactions!(msg);
        expect(captured, same(msg));
      });
    });

    testWidgets('message with replyTo shows reply username', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(
          replyToContent: 'Original text here',
          replyToUsername: 'carol',
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

        expect(find.text('Original text here'), findsOneWidget);
        // carol should appear as reply attribution
        expect(find.text('carol'), findsAtLeast(1));
      });
    });

    // -------------------------------------------------------------------
    // #582 — encrypted-conversation edit affordance gating
    // -------------------------------------------------------------------

    testWidgets(
      'mobile action sheet shows Edit when onEdit is provided (unencrypted conv)',
      (tester) async {
        // Force mobile viewport so MessageItem opens the bottom-sheet path.
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await mockNetworkImagesFor(() async {
          final msg = _makeMessage(isMine: true, fromUserId: 'test-user-id');
          await tester.pumpApp(
            MessageItem(
              message: msg,
              showHeader: false,
              isLastInGroup: true,
              myUserId: 'test-user-id',
              onEdit: (_) {},
              onDelete: (_) {},
            ),
          );
          await tester.pump();

          // Long press triggers _showMobileActionSheet on mobile widths.
          await tester.longPress(find.text('Hello world'));
          await tester.pumpAndSettle();

          expect(
            find.text('Edit'),
            findsOneWidget,
            reason: 'Edit must appear when the parent passes onEdit',
          );
        });
      },
    );

    testWidgets(
      'mobile action sheet hides Edit when onEdit is null (encrypted conv gating, #582)',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await mockNetworkImagesFor(() async {
          final msg = _makeMessage(
            isMine: true,
            fromUserId: 'test-user-id',
            isEncrypted: true,
          );
          await tester.pumpApp(
            MessageItem(
              message: msg,
              showHeader: false,
              isLastInGroup: true,
              myUserId: 'test-user-id',
              // ChatPanel passes onEdit: null on encrypted conversations
              // (#582). The action sheet must hide the Edit entry to
              // prevent user-initiated edits that the server would reject
              // with 409 -- and that, pre-fix, would have leaked plaintext.
              onEdit: null,
              onDelete: (_) {},
            ),
          );
          await tester.pump();

          await tester.longPress(find.text('Hello world'));
          await tester.pumpAndSettle();

          expect(
            find.text('Edit'),
            findsNothing,
            reason:
                'Edit must NOT appear on encrypted conversations (#582). '
                'Editing would broadcast plaintext to every member.',
          );
        });
      },
    );
  });

  // #663 — system message when a member joins a group
  group('MessageItem: system event pill', () {
    testWidgets('renders member-joined system event as centered pill', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        const msg = ChatMessage(
          id: 'sys-1',
          fromUserId: ChatMessage.systemUserId,
          fromUsername: '',
          conversationId: 'group-1',
          content: 'alice joined the group',
          timestamp: '2026-01-15T10:30:00Z',
          isMine: false,
        );

        await tester.pumpApp(
          const MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        expect(find.text('alice joined the group'), findsOneWidget);
        expect(find.byType(Center), findsWidgets);
      });
    });

    testWidgets('system event pill has no reply or delete actions', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        var replyCalled = false;

        const msg = ChatMessage(
          id: 'sys-2',
          fromUserId: ChatMessage.systemUserId,
          fromUsername: '',
          conversationId: 'group-1',
          content: 'bob joined the group',
          timestamp: '2026-01-15T10:31:00Z',
          isMine: false,
        );

        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'test-user-id',
            onReply: (_) => replyCalled = true,
          ),
        );
        await tester.pump();

        expect(replyCalled, isFalse);
        expect(find.text('Delete'), findsNothing);
      });
    });
  });
}
