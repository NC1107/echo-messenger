// Verifies the hover-actions overlay is anchored to the right side of the
// message row at a fixed right: 8 inset, regardless of sender — matching
// the Discord convention where the action bar always appears top-right.
// Previously the overlay anchored to the bubble side (left for received,
// right for sent), which caused asymmetric layout. Both cases are tested
// to confirm neither regresses to the full-width stretch bug (#723).
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
      'received (left-side) overlay anchors right:8 regardless of sender',
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
        expect(overlay.right, 8);
        expect(
          overlay.left,
          isNull,
          reason: 'overlay must not pin its left edge',
        );
      },
    );

    testWidgets('sent (right-side) overlay also anchors right:8', (
      tester,
    ) async {
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
      expect(overlay.right, 8);
      expect(overlay.left, isNull);
    });
  });
}
