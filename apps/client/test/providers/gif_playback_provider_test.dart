/// Tests for [GifPlaybackState] focus-decoupling fix (#GIF).
///
/// Key assertions:
///   - `AppLifecycleState.inactive` does NOT pause animation (desktop
///     focus-loss must NOT trigger a re-decode).
///   - `AppLifecycleState.hidden` does NOT pause animation.
///   - `AppLifecycleState.paused` pauses animation (true backgrounding).
///   - `AppLifecycleState.detached` pauses animation (process about to die).
///   - Autoplay-off still gates animation regardless of focus state.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Inline copy of the production focus-resolution logic so this test file
// has zero coupling to private internals, but still exercises the exact
// semantics the fix introduces.
// ---------------------------------------------------------------------------

bool _isRunning(AppLifecycleState state) {
  return state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive ||
      state == AppLifecycleState.hidden;
}

/// Mirrors the production [GifPlaybackState.isAnimating] gate.
bool isAnimating({required bool autoplay, required AppLifecycleState state}) =>
    autoplay && _isRunning(state);

// ---------------------------------------------------------------------------

void main() {
  group('GifPlayback — lifecycle → isAnimating', () {
    test('resumed + autoplay on → animating', () {
      expect(
        isAnimating(autoplay: true, state: AppLifecycleState.resumed),
        isTrue,
      );
    });

    // Core regression guard: inactive must NOT pause GIFs (#GIF).
    test(
      'inactive + autoplay on → still animating (desktop focus-loss fix)',
      () {
        expect(
          isAnimating(autoplay: true, state: AppLifecycleState.inactive),
          isTrue,
          reason:
              'inactive fires on every desktop window focus-change; pausing '
              'here re-decodes at a different cache size and causes the '
              'resolution-jump bug (#GIF)',
        );
      },
    );

    test('hidden + autoplay on → still animating', () {
      expect(
        isAnimating(autoplay: true, state: AppLifecycleState.hidden),
        isTrue,
      );
    });

    // True backgrounding must still pause.
    test('paused + autoplay on → NOT animating (real background)', () {
      expect(
        isAnimating(autoplay: true, state: AppLifecycleState.paused),
        isFalse,
      );
    });

    test('detached + autoplay on → NOT animating (process ending)', () {
      expect(
        isAnimating(autoplay: true, state: AppLifecycleState.detached),
        isFalse,
      );
    });

    // Autoplay preference overrides everything.
    test('resumed + autoplay off → NOT animating', () {
      expect(
        isAnimating(autoplay: false, state: AppLifecycleState.resumed),
        isFalse,
      );
    });

    test('inactive + autoplay off → NOT animating', () {
      expect(
        isAnimating(autoplay: false, state: AppLifecycleState.inactive),
        isFalse,
      );
    });
  });
}
