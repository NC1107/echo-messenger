import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/reaction.dart';
import 'package:echo_app/src/widgets/input/attachment_preview.dart';
import 'package:echo_app/src/widgets/input/reply_preview_bar.dart';
import 'package:echo_app/src/widgets/message/reaction_bar.dart';
import 'package:echo_app/src/widgets/message/reply_quote.dart';
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

/// Finds a [Semantics] widget whose [label] matches the given string.
Finder _findSemanticsWithLabel(String label) {
  return find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == label,
  );
}

/// Finds a [Semantics] widget whose [label] contains the given substring.
Finder _findSemanticsContaining(String substring) {
  return find.byWidgetPredicate(
    (widget) =>
        widget is Semantics &&
        widget.properties.label != null &&
        widget.properties.label!.contains(substring),
  );
}

void main() {
  group('Semantic labels - MessageItem', () {
    testWidgets('own message has button: true in semantics', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(
          isMine: true,
          fromUserId: 'me',
          content: 'My message',
        );
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: false,
            isLastInGroup: true,
            myUserId: 'me',
          ),
        );
        await tester.pump();

        // Find the Semantics widget with the message label and verify
        // button: true is set.
        final semanticsFinder = find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label ==
                  'Message from alice. Long press for actions.' &&
              widget.properties.button == true,
        );
        expect(semanticsFinder, findsOneWidget);
      });
    });

    testWidgets('other user message also has button: true', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: 'Hello');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'test-user-id',
          ),
        );
        await tester.pump();

        final semanticsFinder = find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label ==
                  'Message from alice. Long press for actions.' &&
              widget.properties.button == true,
        );
        expect(semanticsFinder, findsOneWidget);
      });
    });

    testWidgets('pinned message has "Pinned message" semantic label', (
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

        expect(_findSemanticsWithLabel('Pinned message'), findsOneWidget);
      });
    });

    testWidgets('unpinned message has no "Pinned message" label', (
      tester,
    ) async {
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

        expect(_findSemanticsWithLabel('Pinned message'), findsNothing);
      });
    });

    testWidgets('reply quote has semantic label with content', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(
          replyToContent: 'Original text here',
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

        expect(
          _findSemanticsWithLabel('In reply to bob: Original text here'),
          findsOneWidget,
        );
      });
    });

    testWidgets('file attachment has semantic label with filename', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: '[file:/api/media/report.pdf]');
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

        expect(
          _findSemanticsWithLabel('File attachment: report.pdf'),
          findsOneWidget,
        );
      });
    });

    testWidgets('image attachment has semantic label', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: '[img:/api/media/photo.png]');
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

        expect(_findSemanticsContaining('Image attachment'), findsOneWidget);
      });
    });
  });

  group('Semantic labels - ReactionBar', () {
    testWidgets('single reaction shows "1 reaction:" label', (tester) async {
      await tester.pumpApp(
        ReactionBar(
          reactions: const [
            Reaction(
              messageId: 'm1',
              userId: 'u1',
              username: 'alice',
              emoji: '\u{1F44D}',
            ),
          ],
        ),
      );
      await tester.pump();

      expect(_findSemanticsContaining('1 reaction:'), findsOneWidget);
    });

    testWidgets('multiple reactions shows "N reactions:" label', (
      tester,
    ) async {
      await tester.pumpApp(
        ReactionBar(
          reactions: const [
            Reaction(
              messageId: 'm1',
              userId: 'u1',
              username: 'alice',
              emoji: '\u{1F44D}',
            ),
            Reaction(
              messageId: 'm1',
              userId: 'u2',
              username: 'bob',
              emoji: '\u{2764}',
            ),
          ],
        ),
      );
      await tester.pump();

      expect(_findSemanticsContaining('2 reactions:'), findsOneWidget);
    });

    testWidgets('reaction bar has button: true', (tester) async {
      await tester.pumpApp(
        ReactionBar(
          reactions: const [
            Reaction(
              messageId: 'm1',
              userId: 'u1',
              username: 'alice',
              emoji: '\u{1F44D}',
            ),
          ],
        ),
      );
      await tester.pump();

      final buttonFinder = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.button == true &&
            widget.properties.label != null &&
            widget.properties.label!.contains('reaction'),
      );
      expect(buttonFinder, findsOneWidget);
    });
  });

  group('Semantic labels - ReplyQuote', () {
    testWidgets('shows "In reply to username: content" label', (tester) async {
      await tester.pumpApp(
        const ReplyQuote(
          replyToUsername: 'carol',
          replyToContent: 'Check this out',
          isMine: false,
        ),
      );
      await tester.pump();

      expect(
        _findSemanticsWithLabel('In reply to carol: Check this out'),
        findsOneWidget,
      );
    });

    testWidgets('truncates long reply content in label', (tester) async {
      final longContent = 'A' * 150;
      await tester.pumpApp(
        ReplyQuote(
          replyToUsername: 'dave',
          replyToContent: longContent,
          isMine: false,
        ),
      );
      await tester.pump();

      expect(
        _findSemanticsWithLabel('In reply to dave: ${'A' * 100}...'),
        findsOneWidget,
      );
    });

    testWidgets('uses "Unknown" when username is null', (tester) async {
      await tester.pumpApp(
        const ReplyQuote(
          replyToUsername: null,
          replyToContent: 'Orphaned reply',
          isMine: false,
        ),
      );
      await tester.pump();

      expect(
        _findSemanticsWithLabel('In reply to Unknown: Orphaned reply'),
        findsOneWidget,
      );
    });
  });

  group('Semantic labels - ReplyPreviewBar', () {
    testWidgets('shows "Replying to username: preview" label', (tester) async {
      final msg = _makeMessage(
        fromUsername: 'eve',
        content: 'What do you think?',
      );
      await tester.pumpApp(
        ReplyPreviewBar(replyToMessage: msg, onDismiss: () {}),
      );
      await tester.pump();

      expect(
        _findSemanticsWithLabel('Replying to eve: What do you think?'),
        findsOneWidget,
      );
    });

    testWidgets('dismiss button has semantic label', (tester) async {
      final msg = _makeMessage(content: 'Some content');
      await tester.pumpApp(
        ReplyPreviewBar(replyToMessage: msg, onDismiss: () {}),
      );
      await tester.pump();

      expect(_findSemanticsWithLabel('dismiss reply preview'), findsOneWidget);
    });

    testWidgets('truncates long content in label', (tester) async {
      final longContent = 'B' * 200;
      final msg = _makeMessage(fromUsername: 'frank', content: longContent);
      await tester.pumpApp(
        ReplyPreviewBar(replyToMessage: msg, onDismiss: () {}),
      );
      await tester.pump();

      expect(
        _findSemanticsWithLabel('Replying to frank: ${'B' * 120}...'),
        findsOneWidget,
      );
    });
  });

  group('Semantic labels - AttachmentPreview', () {
    testWidgets('shows "Attached file: filename" label', (tester) async {
      await tester.pumpApp(
        AttachmentPreview(
          attachmentBytes: Uint8List(0),
          fileName: 'photo.png',
          onClear: () {},
        ),
      );
      await tester.pump();

      expect(
        _findSemanticsWithLabel('Attached file: photo.png'),
        findsOneWidget,
      );
    });

    testWidgets('uses "Attachment" when fileName is null', (tester) async {
      await tester.pumpApp(
        AttachmentPreview(
          attachmentBytes: Uint8List(0),
          fileName: null,
          onClear: () {},
        ),
      );
      await tester.pump();

      expect(
        _findSemanticsWithLabel('Attached file: Attachment'),
        findsOneWidget,
      );
    });

    testWidgets('remove button has semantic label', (tester) async {
      await tester.pumpApp(
        AttachmentPreview(
          attachmentBytes: Uint8List(0),
          fileName: 'doc.pdf',
          onClear: () {},
        ),
      );
      await tester.pump();

      expect(_findSemanticsWithLabel('remove attachment'), findsOneWidget);
    });
  });
}
