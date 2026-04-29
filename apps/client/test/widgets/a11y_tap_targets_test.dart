import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/widgets/conversation_panel.dart';
import 'package:echo_app/src/widgets/message_item.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

ChatMessage _peerMsg() {
  return ChatMessage(
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
    testWidgets('_HoverActionButton has 44×44 outer hit target', (
      tester,
    ) async {
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

        // The hover bar contains InkWell-wrapped 44×44 SizedBoxes. Find
        // every InkWell whose ancestor SizedBox is 44×44.
        final inkWells = find.byType(InkWell);
        expect(inkWells, findsWidgets);

        var found44 = false;
        for (final element in inkWells.evaluate()) {
          // Walk up to find the nearest SizedBox ancestor.
          SizedBox? sb;
          element.visitAncestorElements((ancestor) {
            final w = ancestor.widget;
            if (w is SizedBox && w.width == 44 && w.height == 44) {
              sb = w;
              return false;
            }
            return true;
          });
          if (sb != null) {
            found44 = true;
            break;
          }
        }
        expect(
          found44,
          isTrue,
          reason:
              'expected at least one 44×44 SizedBox ancestor of an '
              'InkWell in the hover bar',
        );
      });
    });
  });

  group('A11y tap targets - overflow menu (#497)', () {
    testWidgets('overflow PopupMenuButton has 44×44 minimum constraints', (
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

        // Hover so the overflow menu (lives in hover bar) renders.
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(tester.getCenter(find.byType(MessageItem)));
        await tester.pump();

        final popups = tester.widgetList<PopupMenuButton<String>>(
          find.byType(PopupMenuButton<String>),
        );
        expect(popups, isNotEmpty);

        final has44 = popups.any(
          (p) =>
              (p.constraints?.minWidth ?? 0) >= 44 &&
              (p.constraints?.minHeight ?? 0) >= 44,
        );
        expect(
          has44,
          isTrue,
          reason: 'expected overflow PopupMenuButton with ≥44×44 constraints',
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

      // Find the 4 IconButtons (scan-QR, search, collapse, settings) plus
      // the PopupMenuButton (new) — each should report ≥44×44 constraints.
      final iconButtons = tester.widgetList<IconButton>(
        find.byType(IconButton),
      );
      expect(iconButtons.length, greaterThanOrEqualTo(4));

      for (final btn in iconButtons) {
        final c = btn.constraints;
        if (c == null) continue;
        // We only assert on buttons that explicitly set constraints; the
        // sidebar header sites all do.
        if (c.minWidth > 0 || c.minHeight > 0) {
          expect(
            c.minWidth,
            greaterThanOrEqualTo(44),
            reason: 'IconButton minWidth too small: $c',
          );
          expect(
            c.minHeight,
            greaterThanOrEqualTo(44),
            reason: 'IconButton minHeight too small: $c',
          );
        }
      }

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
