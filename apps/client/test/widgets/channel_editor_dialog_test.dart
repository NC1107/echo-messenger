import 'package:echo_app/src/widgets/channel_editor_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('showCreateChannelDialog', () {
    testWidgets('returns name + default text kind', (tester) async {
      CreateChannelResult? result;
      await _pumpOpener(tester, (ctx) async {
        result = await showCreateChannelDialog(ctx);
      });

      await tester.enterText(find.byType(TextField), 'general');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.name, 'general');
      expect(result!.kind, 'text');
    });

    testWidgets('honours a voice kind selection', (tester) async {
      CreateChannelResult? result;
      await _pumpOpener(tester, (ctx) async {
        result = await showCreateChannelDialog(ctx);
      });

      await tester.enterText(find.byType(TextField), 'lounge');
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Voice').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(result!.kind, 'voice');
    });

    testWidgets('empty name does not submit', (tester) async {
      var completed = false;
      CreateChannelResult? result;
      await _pumpOpener(tester, (ctx) async {
        result = await showCreateChannelDialog(ctx);
        completed = true;
      });

      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      // Dialog stays open; future not resolved.
      expect(completed, isFalse);
      expect(find.text('Add channel'), findsOneWidget);
      expect(result, isNull);
    });

    testWidgets('cancel returns null', (tester) async {
      CreateChannelResult? result = (name: 'x', kind: 'text');
      await _pumpOpener(tester, (ctx) async {
        result = await showCreateChannelDialog(ctx);
      });

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });
  });

  group('showRenameChannelDialog', () {
    testWidgets('returns the new trimmed name', (tester) async {
      String? result;
      await _pumpOpener(tester, (ctx) async {
        result = await showRenameChannelDialog(ctx, currentName: 'general');
      });

      await tester.enterText(find.byType(TextField), '  announcements ');
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await tester.pumpAndSettle();
      expect(result, 'announcements');
    });

    testWidgets('unchanged name returns null', (tester) async {
      String? result = 'sentinel';
      await _pumpOpener(tester, (ctx) async {
        result = await showRenameChannelDialog(ctx, currentName: 'general');
      });

      // Leave the prefilled text as-is and confirm.
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });
  });
}

/// Pump a button that, when tapped, runs [onPressed] with a valid context.
Future<void> _pumpOpener(
  WidgetTester tester,
  Future<void> Function(BuildContext ctx) onPressed,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => onPressed(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
