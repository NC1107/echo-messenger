// Verifies that hovering a message row toggles the action-overlay
// visibility correctly, and that the per-row hover state has been
// migrated from a setState-driven bool to a scoped ValueNotifier so
// expensive bubble children (embedded media, decoded images) don't get
// rebuilt every time the cursor crosses the row (#834, closes #872).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/widgets/message_item.dart';

import '../helpers/pump_app.dart';

ChatMessage _msg() => const ChatMessage(
  id: 'm-1',
  fromUserId: 'u-other',
  fromUsername: 'alice',
  conversationId: 'c-1',
  content: 'hello hover',
  timestamp: '2026-01-15T10:30:00Z',
  isMine: false,
  status: MessageStatus.sent,
);

// Find the hover-overlay's ExcludeSemantics — uniquely identified by
// being a descendant of the Positioned with top: -8 (the overlay anchor
// established by message_item_hover_overlay_test.dart and #723).
ExcludeSemantics _hoverOverlayExclude(WidgetTester tester) {
  final positioned = tester
      .widgetList<Positioned>(find.byType(Positioned))
      .firstWhere((p) => p.top == -8);
  final excludes = find
      .descendant(
        of: find.byWidget(positioned),
        matching: find.byType(ExcludeSemantics),
      )
      .evaluate();
  return excludes.first.widget as ExcludeSemantics;
}

// Verify the three hover-scoped subtrees are each wrapped in a
// ValueListenableBuilder. With setState, none would exist — the
// hover-dependent widgets would just read `_isHovered` directly during
// the parent's build. Three wrappers correspond to: the row-tint
// Container, the inline hover-timestamp AnimatedOpacity, and the
// hover-action overlay.
int _valueListenableBuilderCount(WidgetTester tester) {
  return tester
      .widgetList<ValueListenableBuilder<bool>>(
        find.byType(ValueListenableBuilder<bool>),
      )
      .length;
}

void main() {
  testWidgets('hover enter/exit toggles overlay semantics (#872)', (
    tester,
  ) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpApp(
        MessageItem(
          message: _msg(),
          showHeader: true,
          isLastInGroup: false,
          myUserId: 'me',
        ),
      );
      await tester.pump();

      // Initial: overlay must be excluded from semantics (hidden).
      expect(_hoverOverlayExclude(tester).excluding, isTrue);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(location: Offset.zero);
      await tester.pump();

      final center = tester.getCenter(find.byType(MessageItem));
      await gesture.moveTo(center);
      await tester.pumpAndSettle();

      // After hover-enter the overlay must be revealed.
      expect(_hoverOverlayExclude(tester).excluding, isFalse);

      await gesture.moveTo(const Offset(2000, 2000));
      await tester.pumpAndSettle();

      // After hover-exit the overlay must be hidden again.
      expect(_hoverOverlayExclude(tester).excluding, isTrue);
    });
  });

  testWidgets(
    'continuation-row hover timestamp stays on one line with no AM/PM',
    (tester) async {
      await mockNetworkImagesFor(() async {
        // showHeader:false => avatar slot becomes the narrow hover-time gutter.
        await tester.pumpApp(
          MessageItem(
            message: _msg(),
            showHeader: false,
            isLastInGroup: false,
            myUserId: 'me',
          ),
        );
        await tester.pump();

        final hhmm = RegExp(r'^\d{1,2}:\d{2}$');
        final gutterTimes = tester
            .widgetList<Text>(find.byType(Text))
            .where((t) => t.data != null && hhmm.hasMatch(t.data!))
            .toList();
        expect(
          gutterTimes,
          isNotEmpty,
          reason: 'gutter h:mm timestamp should render on a continuation row',
        );
        for (final t in gutterTimes) {
          expect(t.maxLines, 1, reason: 'gutter time must never wrap');
          expect(t.softWrap, isFalse);
        }
        // The gutter time replaces the below-bubble timestamp on continuation
        // rows, so there is no AM/PM text to crunch into "3:0 / 6 / PM".
        final amPm = tester
            .widgetList<Text>(find.byType(Text))
            .where((t) => (t.data ?? '').contains(RegExp(r'\b(AM|PM)\b')));
        expect(amPm, isEmpty);
      });
    },
  );

  testWidgets(
    'hover state is exposed through scoped ValueListenableBuilder subtrees, not setState (#872)',
    (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpApp(
          MessageItem(
            message: _msg(),
            showHeader: true,
            // !isLastInGroup -> _buildHoverTimestamp is rendered, giving
            // us all three ValueListenableBuilder<bool> subtrees:
            //   1) row-tint Container
            //   2) inline hover-timestamp
            //   3) hover-action overlay
            isLastInGroup: false,
            myUserId: 'me',
          ),
        );
        await tester.pump();

        // The implementation contract: hover-scoped rebuilds live inside
        // dedicated ValueListenableBuilder<bool> wrappers. If the code
        // ever regresses to `setState(() => _isHovered = ...)`, these
        // wrappers disappear and this test fails — flagging that the
        // bubble subtree is once again being rebuilt on every hover.
        expect(
          _valueListenableBuilderCount(tester),
          greaterThanOrEqualTo(3),
          reason:
              'Expected the hover-tint container, inline hover-timestamp '
              'and hover-action overlay to each be wrapped in a scoped '
              'ValueListenableBuilder<bool> so hover does not rebuild '
              'the bubble.',
        );
      });
    },
  );
}
