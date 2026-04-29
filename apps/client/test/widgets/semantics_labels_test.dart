import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/reaction.dart';
import 'package:echo_app/src/widgets/input/pending_attachments_strip.dart';
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

        // Composite label uses 'You' for own messages and includes the
        // long-press affordance.
        final semanticsFinder = find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.button == true &&
              widget.properties.label != null &&
              widget.properties.label!.contains('From You') &&
              widget.properties.label!.contains('Long press for actions'),
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
              widget.properties.button == true &&
              widget.properties.label != null &&
              widget.properties.label!.contains('From alice') &&
              widget.properties.label!.contains('Long press for actions'),
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

  group('Composite message label', () {
    String? findMessageLabel(WidgetTester tester) {
      final widget = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .where(
            (s) =>
                s.properties.button == true &&
                (s.properties.label ?? '').contains('Long press for actions'),
          )
          .firstOrNull;
      return widget?.properties.label;
    }

    testWidgets('includes formatted time string', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(
          content: 'hello',
          timestamp: '2026-01-15T10:30:00Z',
        );
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
          ),
        );
        await tester.pump();

        final label = findMessageLabel(tester);
        expect(label, isNotNull);
        // Format is locale-dependent but always contains a digit + colon.
        expect(label!, contains(' at '));
        expect(RegExp(r'\d{1,2}:\d{2}').hasMatch(label), isTrue);
      });
    });

    testWidgets('plain-text body preview present in label', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: 'Howdy partner');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
          ),
        );
        await tester.pump();

        expect(findMessageLabel(tester), contains('Howdy partner'));
      });
    });

    testWidgets('img token substituted with Image', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: '[img:abc]');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
            serverUrl: 'http://localhost:8080',
          ),
        );
        await tester.pump();

        final label = findMessageLabel(tester);
        expect(label, contains('Image'));
        expect(label, isNot(contains('[img:')));
      });
    });

    testWidgets('file token substituted with File', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: '[file:doc.pdf]');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
            serverUrl: 'http://localhost:8080',
          ),
        );
        await tester.pump();

        final label = findMessageLabel(tester);
        expect(label, contains('File'));
        expect(label, isNot(contains('[file:')));
      });
    });

    testWidgets('voice token substituted with Voice message', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: '[voice:msg]');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
            serverUrl: 'http://localhost:8080',
          ),
        );
        await tester.pump();

        final label = findMessageLabel(tester);
        expect(label, contains('Voice message'));
        expect(label, isNot(contains('[voice:')));
      });
    });

    testWidgets('body truncates to 80 chars with ellipsis', (tester) async {
      await mockNetworkImagesFor(() async {
        final long = 'A' * 200;
        final msg = _makeMessage(content: long);
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
          ),
        );
        await tester.pump();

        final label = findMessageLabel(tester);
        expect(label, contains('${'A' * 80}…'));
        expect(label, isNot(contains('A' * 81)));
      });
    });

    testWidgets('reaction count appears with correct pluralization', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(
          reactions: const [
            Reaction(
              messageId: 'msg-1',
              userId: 'u1',
              username: 'alice',
              emoji: '👍',
            ),
            Reaction(
              messageId: 'msg-1',
              userId: 'u2',
              username: 'bob',
              emoji: '❤️',
            ),
          ],
        );
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
          ),
        );
        await tester.pump();

        expect(findMessageLabel(tester), contains('2 reactions'));
      });
    });

    testWidgets('singular reaction uses singular form', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(
          reactions: const [
            Reaction(
              messageId: 'msg-1',
              userId: 'u1',
              username: 'alice',
              emoji: '👍',
            ),
          ],
        );
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
          ),
        );
        await tester.pump();

        final label = findMessageLabel(tester);
        expect(label, contains('1 reaction'));
        expect(label, isNot(contains('1 reactions')));
      });
    });

    testWidgets('Pinned segment present when pinnedAt set', (tester) async {
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
            myUserId: 'me',
          ),
        );
        await tester.pump();

        expect(findMessageLabel(tester), contains('Pinned'));
      });
    });

    testWidgets('Edited segment present when editedAt set', (tester) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(editedAt: '2026-01-15T11:00:00Z');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
          ),
        );
        await tester.pump();

        expect(findMessageLabel(tester), contains('Edited'));
      });
    });

    testWidgets('End-to-end encrypted segment present when isEncrypted', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(isEncrypted: true);
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
          ),
        );
        await tester.pump();

        expect(findMessageLabel(tester), contains('End-to-end encrypted'));
      });
    });

    testWidgets('all optional segments omitted when none apply', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final msg = _makeMessage(content: 'plain text');
        await tester.pumpApp(
          MessageItem(
            message: msg,
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
          ),
        );
        await tester.pump();

        final label = findMessageLabel(tester)!;
        expect(label, isNot(contains('Pinned')));
        expect(label, isNot(contains('Edited')));
        expect(label, isNot(contains('End-to-end encrypted')));
        expect(label, isNot(contains('reaction')));
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
          isMine: false,
          chatBgColor: const Color(0xFF141415),
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
          isMine: false,
          chatBgColor: const Color(0xFF141415),
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
          isMine: false,
          chatBgColor: const Color(0xFF141415),
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

  group('Semantic labels - PendingAttachmentsStrip', () {
    PendingAttachment makeAttachment({
      String fileName = 'photo.png',
      String mimeType = 'image/png',
      String ext = 'png',
    }) {
      return PendingAttachment(
        bytes: Uint8List(0),
        fileName: fileName,
        mimeType: mimeType,
        ext: ext,
        sizeBytes: 0,
      );
    }

    testWidgets('chip shows "Attached file: filename" label', (tester) async {
      final att = makeAttachment();
      await tester.pumpApp(
        PendingAttachmentsStrip(attachments: [att], onCancel: (_) {}),
      );
      await tester.pump();
      expect(
        _findSemanticsWithLabel('Attached file: photo.png'),
        findsOneWidget,
      );
    });

    testWidgets('cancel button has per-file semantic label', (tester) async {
      final att = makeAttachment(fileName: 'doc.pdf');
      await tester.pumpApp(
        PendingAttachmentsStrip(attachments: [att], onCancel: (_) {}),
      );
      await tester.pump();
      expect(_findSemanticsWithLabel('remove doc.pdf'), findsOneWidget);
    });
  });
}
