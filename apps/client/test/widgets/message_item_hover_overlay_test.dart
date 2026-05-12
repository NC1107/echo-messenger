// Verifies the hover-actions overlay sizes to its child instead of
// stretching across the chat pane on left-side received bubbles (#723).
//
// The overlay is a Positioned widget at top:-28. Anchoring only the side
// closest to the bubble (left for received, right for sent) lets the inner
// action row determine the overlay's width. Setting both `left` and `right`
// would force the overlay to span the full chat width, which is the bug
// #723 reported.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/widgets/message_item.dart';

import '../helpers/pump_app.dart';

ChatMessage _msg({required bool isMine}) => ChatMessage(
  id: isMine ? 'm-mine' : 'm-other',
  fromUserId: isMine ? 'me' : 'u-other',
  fromUsername: isMine ? 'me' : 'alice',
  conversationId: 'c1',
  content: 'short',
  timestamp: '2026-05-06T10:00:00Z',
  isMine: isMine,
  status: MessageStatus.sent,
);

// Find the hover-overlay Positioned widget — uniquely identified by its
// top: -8 placement (Slice 4: bar now overlaps the bubble's top edge).
Positioned _hoverPositioned(WidgetTester tester) {
  return tester
      .widgetList<Positioned>(find.byType(Positioned))
      .firstWhere((p) => p.top == -8);
}

void main() {
  group('Hover overlay anchoring (#723)', () {
    testWidgets(
      'received (left-side) overlay anchors only at left so it sizes to child',
      (tester) async {
        await tester.pumpApp(
          MessageItem(
            message: _msg(isMine: false),
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
          ),
        );
        await tester.pump();

        final overlay = _hoverPositioned(tester);
        expect(overlay.left, 36);
        expect(
          overlay.right,
          isNull,
          reason: 'received bubble overlay must not pin its right edge',
        );
      },
    );

    testWidgets(
      'sent (right-side) overlay anchors only at right so it sizes to child',
      (tester) async {
        await tester.pumpApp(
          MessageItem(
            message: _msg(isMine: true),
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
          ),
        );
        await tester.pump();

        final overlay = _hoverPositioned(tester);
        expect(overlay.left, isNull);
        expect(overlay.right, 0);
      },
    );
  });
}
