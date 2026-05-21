import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/confirm_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

void main() {
  Future<bool>? lastFuture;

  Future<void> pumpOpenDialog(
    WidgetTester tester, {
    bool destructive = false,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    String content = 'Are you sure?',
  }) async {
    await tester.pumpApp(
      Builder(
        builder: (ctx) => TextButton(
          onPressed: () {
            lastFuture = showEchoConfirmDialog(
              ctx,
              title: 'Confirm action',
              content: content,
              confirmLabel: confirmLabel,
              cancelLabel: cancelLabel,
              destructive: destructive,
            );
          },
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('showEchoConfirmDialog', () {
    testWidgets('renders the title and content', (tester) async {
      await pumpOpenDialog(tester);
      expect(find.text('Confirm action'), findsOneWidget);
      expect(find.text('Are you sure?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await lastFuture;
    });

    testWidgets('confirm tap resolves the future to true', (tester) async {
      await pumpOpenDialog(tester);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(await lastFuture, isTrue);
    });

    testWidgets('cancel tap resolves the future to false', (tester) async {
      await pumpOpenDialog(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await lastFuture, isFalse);
    });

    testWidgets('destructive: true paints the title in the danger colour', (
      tester,
    ) async {
      await pumpOpenDialog(tester, destructive: true);
      final titleWidget = tester.widget<Text>(find.text('Confirm action'));
      expect(titleWidget.style?.color, EchoTheme.danger);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await lastFuture;
    });

    testWidgets('custom labels appear on the buttons', (tester) async {
      await pumpOpenDialog(tester, confirmLabel: 'Delete', cancelLabel: 'Keep');
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Keep'), findsOneWidget);
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      await lastFuture;
    });
  });
}
