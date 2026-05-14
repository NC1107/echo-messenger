import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/skeleton_loader.dart';
import 'package:echo_app/src/widgets/typing_bubble.dart';

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

void main() {
  group('reduced-motion: SkeletonLoader', () {
    testWidgets('renders a ShaderMask shimmer with animations enabled', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const ConversationSkeleton()));
      await tester.pump();

      expect(find.byType(ShaderMask), findsOneWidget);
    });

    testWidgets('omits the ShaderMask shimmer under reduced-motion', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const ConversationSkeleton(), reduceMotion: true),
      );
      await tester.pump();

      // With disableAnimations the shimmer short-circuits to the static
      // child tree — no animated gradient sweep is rendered.
      expect(find.byType(ShaderMask), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('MessageSkeleton also drops the shimmer under reduced-motion', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const MessageSkeleton(), reduceMotion: true),
      );
      await tester.pump();

      expect(find.byType(ShaderMask), findsNothing);
    });
  });

  group('reduced-motion: TypingDots', () {
    testWidgets('controller is animating with motion enabled', (tester) async {
      await tester.pumpWidget(_wrap(const TypingDots()));
      await tester.pump();

      final state = tester.state<TypingDotsState>(find.byType(TypingDots));
      expect(state.isAnimating, isTrue);
    });

    testWidgets('controller is paused under reduced-motion', (tester) async {
      await tester.pumpWidget(_wrap(const TypingDots(), reduceMotion: true));
      await tester.pump();

      final state = tester.state<TypingDotsState>(find.byType(TypingDots));
      expect(state.isAnimating, isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}
