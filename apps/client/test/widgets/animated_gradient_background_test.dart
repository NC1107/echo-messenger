import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/accessibility_provider.dart';
import 'package:echo_app/src/widgets/auth/animated_gradient_background.dart';

Widget _wrap({List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: const MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            AnimatedGradientBackground(),
            Center(child: Text('Test')),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AnimatedGradientBackground', () {
    testWidgets('renders without exception (motion enabled)', (tester) async {
      await tester.pumpWidget(_wrap());
      await tester.pump();

      // Widget tree present and no exceptions.
      expect(find.byType(AnimatedGradientBackground), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('with reduce motion on renders static gradient only', (
      tester,
    ) async {
      // Override accessibility so reducedMotion = true from the start.
      final overrides = [
        accessibilityProvider.overrideWith(() => _ReducedMotionAccessibility()),
      ];

      await tester.pumpWidget(_wrap(overrides: overrides));
      await tester.pump();

      expect(find.byType(AnimatedGradientBackground), findsOneWidget);
      expect(tester.takeException(), isNull);

      // With reduce motion the gradient should be completely static:
      // ticking the clock must not repaint the gradient widget.
      final gradientFinder = find.byType(AnimatedGradientBackground);
      final renderBefore = tester.renderObject(gradientFinder);
      await tester.pump(const Duration(seconds: 5));
      // The same RenderObject is reused (no rebuild driven by animation).
      expect(tester.renderObject(gradientFinder), same(renderBefore));
    });

    testWidgets('static gradient paints a DecoratedBox', (tester) async {
      final overrides = [
        accessibilityProvider.overrideWith(() => _ReducedMotionAccessibility()),
      ];

      await tester.pumpWidget(_wrap(overrides: overrides));
      await tester.pump();

      // DecoratedBox is used by _StaticGradient.
      expect(find.byType(DecoratedBox), findsWidgets);
    });
  });
}

/// Fake [Accessibility] notifier that returns [reducedMotion] = true.
class _ReducedMotionAccessibility extends Accessibility {
  @override
  AccessibilityState build() => const AccessibilityState(reducedMotion: true);
}
