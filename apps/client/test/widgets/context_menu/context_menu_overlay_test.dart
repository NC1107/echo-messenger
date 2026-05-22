import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/context_menu/actions/message_actions_registry.dart';
import 'package:echo_app/src/widgets/context_menu/context_menu_overlay.dart';
import 'package:echo_app/src/widgets/context_menu/echo_context_menu.dart';

/// Pump a host scaffold then open the overlay anchored near the top-left.
Future<void> _openOverlay(WidgetTester tester, ContextMenuModel model) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showContextMenuOverlay(
                context: context,
                anchor: const Offset(40, 40),
                model: model,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  group('showContextMenuOverlay', () {
    testWidgets('renders rows for every action in the model', (tester) async {
      final model = ContextMenuModel(
        sections: [
          ContextMenuSection(
            actions: [
              ContextMenuAction(
                label: 'Reply',
                icon: Icons.reply,
                onTap: () {},
              ),
              ContextMenuAction(
                label: 'Forward',
                icon: Icons.shortcut,
                onTap: () {},
              ),
            ],
          ),
        ],
      );
      await _openOverlay(tester, model);

      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Forward'), findsOneWidget);
    });

    testWidgets('tapping a row invokes the action callback and dismisses', (
      tester,
    ) async {
      var tapped = 0;
      final model = ContextMenuModel(
        sections: [
          ContextMenuSection(
            actions: [
              ContextMenuAction(
                label: 'Copy Text',
                icon: Icons.copy,
                onTap: () => tapped++,
              ),
            ],
          ),
        ],
      );
      await _openOverlay(tester, model);
      expect(find.text('Copy Text'), findsOneWidget);

      await tester.tap(find.text('Copy Text'));
      await tester.pumpAndSettle();

      // Action runs in a post-frame callback after the route is popped.
      await tester.pump();
      expect(tapped, 1);
      // Menu has been dismissed.
      expect(find.text('Copy Text'), findsNothing);
    });

    testWidgets('submenu action pushes a nested menu with a back affordance', (
      tester,
    ) async {
      final model = ContextMenuModel(
        sections: [
          ContextMenuSection(
            actions: [
              ContextMenuAction(
                label: 'Change Role',
                icon: Icons.admin_panel_settings_outlined,
                submenu: [
                  ContextMenuSection(
                    actions: [
                      ContextMenuAction(
                        label: 'Admin',
                        icon: Icons.shield_outlined,
                        onTap: () {},
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      await _openOverlay(tester, model);

      await tester.tap(find.text('Change Role'));
      await tester.pumpAndSettle();

      // After push, the submenu's row + its back-header title are visible.
      expect(find.text('Admin'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    });

    testWidgets(
      'right-click message menu surfaces "Add reaction" labeled row',
      (tester) async {
        // Drive the menu through the same registry the real chat panel
        // uses so this test catches regressions where the row drops out
        // of the rendered tree.
        var pickerOpened = 0;
        final target = MessageTarget(
          message: const _StubMessage(),
          isMine: false,
          isSaved: false,
          isEncryptedUnreadable: false,
          mediaUrl: null,
          isImageMedia: false,
          onReply: () {},
          onForward: () {},
          onCopyText: () {},
          onDelete: () {},
          onCopyId: () {},
          onPickReaction: (_) {},
          onOpenFullPicker: () => pickerOpened++,
        );
        final model = buildMessageMenu(target);
        await _openOverlay(tester, model);

        expect(find.text('Add reaction'), findsOneWidget);

        await tester.tap(find.text('Add reaction'));
        await tester.pumpAndSettle();
        await tester.pump();

        expect(pickerOpened, 1);
      },
    );

    testWidgets('inline reactions header renders four emojis', (tester) async {
      final model = ContextMenuModel(
        header: InlineReactionsHeader(
          emojis: const ['A', 'B', 'C', 'D'],
          onPick: (_) {},
          onOpenFullPicker: () {},
        ),
        sections: const [],
      );
      await _openOverlay(tester, model);

      // The reactions header surfaces every emoji as a tap target.
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      expect(find.text('D'), findsOneWidget);
      // Plus the "open full picker" affordance.
      expect(find.byIcon(Icons.add_reaction_outlined), findsOneWidget);
    });
  });
}

/// Stand-in for ChatMessage so the registry tests don't pull the whole
/// chat-provider import graph in.
class _StubMessage {
  const _StubMessage();
}
