import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/toast_service.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

// Wraps the app with the Echo dark theme so theme extensions resolve in tests.
Widget _harness() {
  return MaterialApp(
    theme: EchoTheme.darkTheme,
    home: Scaffold(
      body: Builder(
        builder: (ctx) =>
            Center(child: Builder(builder: (innerCtx) => const Text('tap'))),
      ),
    ),
  );
}

void main() {
  tearDown(() {
    // Drain any pending timers that ToastService installs so tests don't leak.
  });

  group('ToastService keyboard-safe positioning', () {
    testWidgets('success toast renders without errors (keyboard closed)', (
      tester,
    ) async {
      await tester.pumpWidget(_harness());
      await tester.pump();

      final ctx = tester.element(find.text('tap'));
      ToastService.show(ctx, 'Saved!', type: ToastType.success);
      await tester.pump();

      expect(find.text('Saved!'), findsOneWidget);

      // Drain the dismiss timer (3 s default).
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('error toast renders without errors', (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pump();

      final ctx = tester.element(find.text('tap'));
      ToastService.show(ctx, 'Only admins can pin', type: ToastType.error);
      await tester.pump();

      expect(find.text('Only admins can pin'), findsOneWidget);

      // Drain the dismiss timer.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('second show replaces first toast', (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pump();

      final ctx = tester.element(find.text('tap'));
      ToastService.show(ctx, 'First', type: ToastType.info);
      await tester.pump();

      ToastService.show(ctx, 'Second', type: ToastType.info);
      await tester.pump();

      // Only the second toast should be visible.
      expect(find.text('Second'), findsOneWidget);
      expect(find.text('First'), findsNothing);

      await tester.pump(const Duration(seconds: 4));
    });
  });
}
