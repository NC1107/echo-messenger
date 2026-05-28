import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/widgets/voice_lounge/encrypted_canvas_notice.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('trigger-encrypted'),
                onPressed: () =>
                    EncryptedCanvasNotice.maybeShow(context, isEncrypted: true),
                child: const Text('open-encrypted'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows dialog on first call when isEncrypted is true', (
    tester,
  ) async {
    await pumpHost(tester);
    await tester.tap(find.byKey(const Key('trigger-encrypted')));
    await tester.pumpAndSettle();
    expect(find.text("Canvas isn't encrypted yet"), findsOneWidget);
    expect(find.text('Got it'), findsOneWidget);
  });

  testWidgets('does NOT show when isEncrypted is false', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const Key('trigger-plain'),
              onPressed: () =>
                  EncryptedCanvasNotice.maybeShow(context, isEncrypted: false),
              child: const Text('open-plain'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('trigger-plain')));
    await tester.pumpAndSettle();
    expect(find.text("Canvas isn't encrypted yet"), findsNothing);
  });

  testWidgets('sets the seen flag after dismiss + does not show again', (
    tester,
  ) async {
    await pumpHost(tester);
    await tester.tap(find.byKey(const Key('trigger-encrypted')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(EncryptedCanvasNotice.prefsKey), isTrue);

    await tester.tap(find.byKey(const Key('trigger-encrypted')));
    await tester.pumpAndSettle();
    expect(find.text("Canvas isn't encrypted yet"), findsNothing);
  });

  testWidgets('skips when seen flag is already true', (tester) async {
    SharedPreferences.setMockInitialValues({
      EncryptedCanvasNotice.prefsKey: true,
    });
    await pumpHost(tester);
    await tester.tap(find.byKey(const Key('trigger-encrypted')));
    await tester.pumpAndSettle();
    expect(find.text("Canvas isn't encrypted yet"), findsNothing);
  });
}
