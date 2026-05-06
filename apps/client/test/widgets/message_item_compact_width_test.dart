// Verifies the bubble Container's max-width constraint differs between
// the bubble layout (capped at 520) and compact/plain layouts (uncapped),
// so Compact/Plain flow to the chat-pane width like Discord/Slack (#794).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/providers/theme_provider.dart';
import 'package:echo_app/src/widgets/message_item.dart';

import '../helpers/pump_app.dart';

ChatMessage _msg() => const ChatMessage(
  id: 'm1',
  fromUserId: 'u-other',
  fromUsername: 'alice',
  conversationId: 'c1',
  content: 'A reasonably long message that would otherwise hit the bubble cap.',
  timestamp: '2026-05-06T10:00:00Z',
  isMine: false,
  status: MessageStatus.sent,
);

// Find the message bubble Container — uniquely identified as the Container
// that has a BoxDecoration AND wraps its child in MergeSemantics (the avatar
// column / hover overlay containers don't share that structure).
Container _bubble(WidgetTester tester) {
  return tester
      .widgetList<Container>(find.byType(Container))
      .firstWhere(
        (c) => c.decoration is BoxDecoration && c.child is MergeSemantics,
      );
}

void main() {
  group('Bubble width constraint by layout (#794)', () {
    testWidgets('bubble layout caps width at 520', (tester) async {
      await tester.pumpApp(
        MessageItem(
          message: _msg(),
          showHeader: true,
          isLastInGroup: true,
          myUserId: 'me',
          // default: MessageLayout.bubbles
        ),
      );
      await tester.pump();

      expect(_bubble(tester).constraints!.maxWidth, 520);
    });

    testWidgets('compact layout removes the 520 cap', (tester) async {
      await tester.pumpApp(
        MessageItem(
          message: _msg(),
          showHeader: true,
          isLastInGroup: true,
          myUserId: 'me',
          layout: MessageLayout.compact,
        ),
      );
      await tester.pump();

      expect(_bubble(tester).constraints!.maxWidth, double.infinity);
    });

    testWidgets('plain layout removes the 520 cap', (tester) async {
      await tester.pumpApp(
        MessageItem(
          message: _msg(),
          showHeader: true,
          isLastInGroup: true,
          myUserId: 'me',
          layout: MessageLayout.plain,
        ),
      );
      await tester.pump();

      expect(_bubble(tester).constraints!.maxWidth, double.infinity);
    });
  });
}
