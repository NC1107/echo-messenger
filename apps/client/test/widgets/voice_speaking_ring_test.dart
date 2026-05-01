import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/voice_speaking_ring.dart';

Widget _wrap(Widget child, {bool reduceMotion = false}) {
  return MaterialApp(
    theme: EchoTheme.darkTheme,
    darkTheme: EchoTheme.darkTheme,
    themeMode: ThemeMode.dark,
    builder: (context, widget) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: widget!,
    ),
    home: Scaffold(body: Center(child: child)),
  );
}

// Predicate that finds a DecoratedBox whose border has a non-transparent color,
// i.e. the green speaking ring is rendered.
bool _hasVisibleRing(Widget widget) {
  if (widget is DecoratedBox) {
    final decoration = widget.decoration;
    if (decoration is BoxDecoration) {
      final border = decoration.border;
      if (border is Border) {
        return border.top.color.a > 0;
      }
    }
  }
  return false;
}

void main() {
  group('VoiceSpeakingRing', () {
    testWidgets('ring is visible when audioLevel exceeds threshold', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const VoiceSpeakingRing(
            audioLevel: 0.3,
            child: SizedBox(width: 48, height: 48),
          ),
        ),
      );
      await tester.pump();

      expect(find.byWidgetPredicate(_hasVisibleRing), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ring is NOT visible when audioLevel is below threshold', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const VoiceSpeakingRing(
            audioLevel: 0.01,
            child: SizedBox(width: 48, height: 48),
          ),
        ),
      );
      await tester.pump();

      // When silent the child is returned directly -- no ring DecoratedBox.
      expect(find.byWidgetPredicate(_hasVisibleRing), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'with reduce-motion ring is static (controller not animating)',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            const VoiceSpeakingRing(
              audioLevel: 0.3,
              child: SizedBox(width: 48, height: 48),
            ),
            reduceMotion: true,
          ),
        );
        await tester.pump();

        // In reduce-motion mode the animation controller must not be animating.
        final ringState = tester.state<VoiceSpeakingRingState>(
          find.byType(VoiceSpeakingRing),
        );
        expect(ringState.isAnimating, isFalse);

        // A static ring is still rendered.
        expect(find.byWidgetPredicate(_hasVisibleRing), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'animation starts when audioLevel transitions above threshold',
      (tester) async {
        // Start silent.
        await tester.pumpWidget(
          _wrap(
            const VoiceSpeakingRing(
              key: ValueKey('ring'),
              audioLevel: 0.0,
              child: SizedBox(width: 48, height: 48),
            ),
          ),
        );
        await tester.pump();

        final state1 = tester.state<VoiceSpeakingRingState>(
          find.byKey(const ValueKey('ring')),
        );
        expect(state1.isAnimating, isFalse);

        // Rebuild with speaking level.
        await tester.pumpWidget(
          _wrap(
            const VoiceSpeakingRing(
              key: ValueKey('ring'),
              audioLevel: 0.4,
              child: SizedBox(width: 48, height: 48),
            ),
          ),
        );
        await tester.pump();

        final state2 = tester.state<VoiceSpeakingRingState>(
          find.byKey(const ValueKey('ring')),
        );
        expect(state2.isAnimating, isTrue);
      },
    );
  });
}
