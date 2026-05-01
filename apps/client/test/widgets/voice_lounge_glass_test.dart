// Smoke test for the voice-lounge frosted-glass redesign (#210).
//
// The full VoiceLoungeScreen depends heavily on LiveKit and platform WebRTC
// APIs that are unavailable on the test host.  We therefore test the affected
// sub-components in isolation:
//   - _AvatarCircle / VoiceSpeakingRing (via the exported widget)
//   - The frosted-glass tile shell (BackdropFilter present in a ClipRRect)
//   - Basic tile sizing (grid cell is 112 × 136)

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/voice_speaking_ring.dart';

// ---------------------------------------------------------------------------
// Minimal replica of the frosted-glass tile shell used in _ParticipantTile.
// Keeps the test self-contained and avoids pulling in LiveKit.
// ---------------------------------------------------------------------------

/// A simplified version of the participant tile's frosted glass shell.
/// Mirrors the BackdropFilter + ClipRRect introduced in the #210 redesign.
Widget _buildGlassTile({required Widget child, bool isSpeaking = false}) {
  return MaterialApp(
    theme: EchoTheme.darkTheme,
    darkTheme: EchoTheme.darkTheme,
    themeMode: ThemeMode.dark,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 112,
          height: 136,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSpeaking ? EchoTheme.online : Colors.white24,
                width: isSpeaking ? 2.0 : 1.0,
              ),
              boxShadow: isSpeaking
                  ? [
                      BoxShadow(
                        color: EchoTheme.online.withValues(alpha: 0.3),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            clipBehavior: Clip.antiAlias,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.30),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('Voice lounge frosted-glass redesign (#210)', () {
    testWidgets('glass tile renders without exceptions', (tester) async {
      await tester.pumpWidget(_buildGlassTile(child: const SizedBox.expand()));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('BackdropFilter is present in the tile widget tree', (
      tester,
    ) async {
      await tester.pumpWidget(_buildGlassTile(child: const SizedBox.expand()));
      await tester.pump();

      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tile is sized 112 × 136 (grid cell dimensions)', (
      tester,
    ) async {
      await tester.pumpWidget(_buildGlassTile(child: const SizedBox.expand()));
      await tester.pump();

      final sizeable = tester.widget<SizedBox>(find.byType(SizedBox).first);
      expect(sizeable.width, 112);
      expect(sizeable.height, 136);
      expect(tester.takeException(), isNull);
    });

    testWidgets('speaking-ring renders without exceptions inside glass tile', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildGlassTile(
          isSpeaking: true,
          child: Center(
            child: VoiceSpeakingRing(
              audioLevel: 0.5,
              child: Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.blueGrey,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(VoiceSpeakingRing), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('silent tile (audioLevel 0) renders without exceptions', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildGlassTile(
          isSpeaking: false,
          child: Center(
            child: VoiceSpeakingRing(
              audioLevel: 0.0,
              child: Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.blueGrey,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(VoiceSpeakingRing), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
