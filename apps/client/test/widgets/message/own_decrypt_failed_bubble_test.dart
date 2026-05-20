import 'package:echo_app/src/widgets/message/message_indicators.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/pump_app.dart';

/// Widget tests for [OwnDecryptFailedBubble] — the recovery surface
/// the sender sees when their own group message couldn't be decrypted
/// back to self (group-E2E wedge per CLAUDE.md #344). Locks down the
/// callback wiring and the "only you can see this" copy (TD-23).
void main() {
  group('OwnDecryptFailedBubble', () {
    testWidgets('renders original text and the "only you" footer', (
      tester,
    ) async {
      await tester.pumpApp(
        OwnDecryptFailedBubble(
          originalText: 'meet at 7',
          onResend: () {},
          onDelete: () {},
        ),
      );

      expect(find.text('meet at 7'), findsOneWidget);
      expect(find.textContaining("Only you can see this"), findsOneWidget);
    });

    testWidgets('Resend button fires onResend', (tester) async {
      var resends = 0;
      await tester.pumpApp(
        OwnDecryptFailedBubble(
          originalText: 'meet at 7',
          onResend: () => resends++,
          onDelete: () {},
        ),
      );
      await tester.tap(find.text('Resend'));
      expect(resends, 1);
    });

    testWidgets('Delete button fires onDelete', (tester) async {
      var deletes = 0;
      await tester.pumpApp(
        OwnDecryptFailedBubble(
          originalText: 'meet at 7',
          onResend: () {},
          onDelete: () => deletes++,
        ),
      );
      await tester.tap(find.text('Delete'));
      expect(deletes, 1);
    });

    testWidgets('omits Resend/Delete buttons when callbacks are null', (
      tester,
    ) async {
      await tester.pumpApp(
        const OwnDecryptFailedBubble(originalText: 'meet at 7'),
      );
      expect(find.text('Resend'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(find.text('meet at 7'), findsOneWidget);
    });

    testWidgets('original text renders at reduced opacity', (tester) async {
      await tester.pumpApp(
        OwnDecryptFailedBubble(originalText: 'meet at 7', onResend: () {}),
      );
      final opacityWidget = tester.widget<Opacity>(
        find.ancestor(
          of: find.text('meet at 7'),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacityWidget.opacity, lessThan(1.0));
      expect(opacityWidget.opacity, greaterThan(0.5));
    });
  });
}
