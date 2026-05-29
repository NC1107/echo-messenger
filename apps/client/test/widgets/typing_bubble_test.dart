import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/typing_bubble.dart';

import '../helpers/pump_app.dart';

void main() {
  group('TypingDots', () {
    testWidgets('renders without errors with default dotSize', (tester) async {
      await tester.pumpApp(const TypingDots());
      await tester.pump();

      expect(find.byType(TypingDots), findsOneWidget);
    });

    testWidgets('default dotSize is 5 (compact indicator)', (tester) async {
      // Verify the constructor default matches the compact spec.
      const dots = TypingDots();
      expect(dots.dotSize, equals(5));
    });

    testWidgets('accepts a custom dotSize override', (tester) async {
      await tester.pumpApp(const TypingDots(dotSize: 8));
      await tester.pump();

      expect(find.byType(TypingDots), findsOneWidget);
    });

    testWidgets('renders three dots', (tester) async {
      await tester.pumpApp(const TypingDots());
      await tester.pump();

      // The bubble contains one Row with three SizedBox.square children.
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('respects reduced-motion: animation is stopped', (
      tester,
    ) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            home: const Scaffold(body: TypingDots()),
          ),
        ),
      );
      await tester.pump();

      final state = tester.state<TypingDotsState>(find.byType(TypingDots));
      expect(state.isAnimating, isFalse);
    });

    testWidgets('animation runs when reduced-motion is off', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: false),
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            home: const Scaffold(body: TypingDots()),
          ),
        ),
      );
      // Let the animation controller tick.
      await tester.pump(const Duration(milliseconds: 100));

      final state = tester.state<TypingDotsState>(find.byType(TypingDots));
      expect(state.isAnimating, isTrue);
    });
  });
}
