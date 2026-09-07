import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/widgets/conversation_panel.dart';
import 'package:echo_app/src/widgets/message/message_actions.dart';
import 'package:echo_app/src/widgets/message_item.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

ChatMessage _peerMsg() {
  return const ChatMessage(
    id: 'msg-1',
    fromUserId: 'user-alice',
    fromUsername: 'alice',
    conversationId: 'conv-1',
    content: 'Hello',
    timestamp: '2026-01-15T10:00:00Z',
    isMine: false,
    isEncrypted: true,
  );
}

void main() {
  group('A11y tap targets - hover action buttons (#497)', () {
    testWidgets('_HoverActionButton has 33×33 outer hit target', (
      tester,
    ) async {
      // Slice 4: hover-action chips were scaled to 75% (33×33 hit /
      // 21×21 visual). Still well above the Material 24px minimum for
      // dense desktop UIs.
      await mockNetworkImagesFor(() async {
        // Force a desktop-sized window so the hover bar can render.
        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpApp(
          MessageItem(
            message: _peerMsg(),
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
            // After the hover-action overhaul, the reply/forward buttons
            // are gated on callbacks being non-null — pass stubs here so
            // the 33×33 hit-target contract still has a button to check.
            actions: MessageActions(onReply: (_) {}, onForward: (_) {}),
          ),
        );
        await tester.pump();

        // Simulate a mouse hover so the hover bar renders.
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(tester.getCenter(find.byType(MessageItem)));
        await tester.pump();

        // The hover bar contains InkWell-wrapped 33×33 SizedBoxes. Find
        // every InkWell whose ancestor SizedBox is 33×33.
        final inkWells = find.byType(InkWell);
        expect(inkWells, findsWidgets);

        var found33 = false;
        for (final element in inkWells.evaluate()) {
          // Walk up to find the nearest SizedBox ancestor.
          SizedBox? sb;
          element.visitAncestorElements((ancestor) {
            final w = ancestor.widget;
            if (w is SizedBox && w.width == 33 && w.height == 33) {
              sb = w;
              return false;
            }
            return true;
          });
          if (sb != null) {
            found33 = true;
            break;
          }
        }
        expect(
          found33,
          isTrue,
          reason:
              'expected at least one 33×33 SizedBox ancestor of an '
              'InkWell in the hover bar',
        );
      });
    });
  });

  group('A11y tap targets - overflow menu (#497)', () {
    testWidgets('overflow "More actions" button renders ≥44×44', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpApp(
          MessageItem(
            message: _peerMsg(),
            showHeader: true,
            isLastInGroup: true,
            myUserId: 'me',
          ),
        );
        await tester.pump();

        // Hover so the overflow affordance (lives in hover bar) renders.
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(tester.getCenter(find.byType(MessageItem)));
        await tester.pump();

        // Post-PR 2: the overflow PopupMenuButton was replaced with a
        // plain InkWell wrapped in a sized box that routes through
        // EchoContextMenu. The semantics label is still "More actions";
        // we assert the rendered hit area meets WCAG via the box size.
        final finder = find.bySemanticsLabel('More actions');
        expect(finder, findsOneWidget);
        final size = tester.getSize(finder);
        expect(
          size.width,
          greaterThanOrEqualTo(44),
          reason: 'overflow affordance width must be ≥44 (WCAG)',
        );
        expect(
          size.height,
          greaterThanOrEqualTo(44),
          reason: 'overflow affordance height must be ≥44 (WCAG)',
        );
      });
    });
  });

  group('A11y tap targets - sidebar header IconButtons (#498)', () {
    testWidgets('all sidebar header IconButtons measure ≥44×44', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpApp(
        ConversationPanel(
          onConversationTap: (_) {},
          onScanQr: () {},
          onNewChat: () {},
          onNewGroup: () {},
          onDiscover: () {},
          onSavedMessages: () {},
          onCollapseSidebar: () {},
          onSettings: () {},
          onGlobalSearch: () {},
        ),
        overrides: standardOverrides(),
      );
      await tester.pump();

      // Sidebar header has IconButtons that we explicitly bumped to 44×44
      // for #498.  Count how many satisfy the WCAG 2.5.5 minimum so a
      // regression that drops a constraint (or sets it to zero) shows up
      // as a coverage shortfall instead of slipping past a guarded loop.
      final iconButtons = tester.widgetList<IconButton>(
        find.byType(IconButton),
      );
      var compliantCount = 0;
      for (final btn in iconButtons) {
        final c = btn.constraints;
        if (c == null) continue;
        if (c.minWidth >= 44 && c.minHeight >= 44) {
          compliantCount++;
        } else if (c.minWidth > 0 || c.minHeight > 0) {
          fail(
            'IconButton has explicit constraints below 44×44: $c '
            '(WCAG 2.5.5 minimum)',
          );
        }
      }
      // We expect at least the 3 always-rendered header IconButtons:
      // scan-QR, search, collapse.  The settings button lives in
      // _buildUserStatusBar which only renders when authenticated and is
      // not exercised here -- visual confirmation suffices for that one.
      expect(
        compliantCount,
        greaterThanOrEqualTo(3),
        reason: 'expected ≥3 sidebar IconButtons with 44×44 constraints',
      );

      // The "new" PopupMenuButton in the header.
      final popups = tester.widgetList<PopupMenuButton<String>>(
        find.byType(PopupMenuButton<String>),
      );
      expect(popups, isNotEmpty);
      final newMenu = popups.firstWhere(
        (p) =>
            (p.constraints?.minWidth ?? 0) >= 44 &&
            (p.constraints?.minHeight ?? 0) >= 44,
        orElse: () => popups.first,
      );
      expect((newMenu.constraints?.minWidth ?? 0), greaterThanOrEqualTo(44));
      expect((newMenu.constraints?.minHeight ?? 0), greaterThanOrEqualTo(44));
    });
  });
}
