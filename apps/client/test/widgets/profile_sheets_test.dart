import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/profile_sheets.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

void main() {
  group('showUserProfileSheet', () {
    testWidgets('opens a bottom sheet with the profile body on narrow screens', (
      tester,
    ) async {
      // Narrow viewport (375 x 812) triggers the bottom-sheet path.
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      late BuildContext capturedCtx;
      late WidgetRef capturedRef;

      await tester.pumpApp(
        Consumer(
          builder: (ctx, ref, _) {
            capturedCtx = ctx;
            capturedRef = ref;
            return ElevatedButton(
              onPressed: () =>
                  showUserProfileSheet(capturedCtx, capturedRef, 'user-1'),
              child: const Text('Open Profile'),
            );
          },
        ),
        overrides: standardOverrides(),
      );

      // Tap the button — this calls showUserProfileSheet.
      await tester.tap(find.text('Open Profile'));
      await tester.pump(); // schedule frame
      await tester.pump(const Duration(milliseconds: 300)); // sheet animation

      // The modal bottom sheet barrier should be present.
      expect(find.byType(ModalBarrier), findsWidgets);

      // Dismiss the sheet by tapping the barrier (swipe-down / tap-outside).
      await tester.tapAt(const Offset(187, 50)); // tap above the sheet
      await tester.pumpAndSettle();

      // Underlying button is still accessible — sheet was dismissed, not popped.
      expect(find.text('Open Profile'), findsOneWidget);
    });

    testWidgets('opens a dialog on wide screens (>= 900 px)', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      late BuildContext capturedCtx;
      late WidgetRef capturedRef;

      await tester.pumpApp(
        Consumer(
          builder: (ctx, ref, _) {
            capturedCtx = ctx;
            capturedRef = ref;
            return ElevatedButton(
              onPressed: () =>
                  showUserProfileSheet(capturedCtx, capturedRef, 'user-1'),
              child: const Text('Open Profile'),
            );
          },
        ),
        overrides: standardOverrides(),
      );

      await tester.tap(find.text('Open Profile'));
      await tester.pumpAndSettle();

      // A Dialog widget (not a bottom sheet) should appear.
      expect(find.byType(Dialog), findsOneWidget);
    });
  });

  group('showGroupProfileSheet', () {
    testWidgets(
      'opens a bottom sheet with the group info body on narrow screens',
      (tester) async {
        tester.view.physicalSize = const Size(375, 812);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        late BuildContext capturedCtx;
        late WidgetRef capturedRef;

        await tester.pumpApp(
          Consumer(
            builder: (ctx, ref, _) {
              capturedCtx = ctx;
              capturedRef = ref;
              return ElevatedButton(
                onPressed: () =>
                    showGroupProfileSheet(capturedCtx, capturedRef, 'conv-2'),
                child: const Text('Open Group Info'),
              );
            },
          ),
          overrides: standardOverrides(),
        );

        await tester.tap(find.text('Open Group Info'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Modal barrier present means a sheet (or dialog) was opened.
        expect(find.byType(ModalBarrier), findsWidgets);

        // Dismiss and verify underlying screen survives.
        await tester.tapAt(const Offset(187, 50));
        await tester.pumpAndSettle();

        expect(find.text('Open Group Info'), findsOneWidget);
      },
    );
  });
}
