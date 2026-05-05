import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/screen_share_provider.dart';

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('ScreenShareState', () {
    test('initial state is not sharing with no error', () {
      const state = ScreenShareState.empty;
      expect(state.isScreenSharing, isFalse);
      expect(state.error, isNull);
    });

    test('copyWith updates isScreenSharing', () {
      const state = ScreenShareState.empty;
      final updated = state.copyWith(isScreenSharing: true);
      expect(updated.isScreenSharing, isTrue);
      expect(updated.error, isNull);
    });

    test('copyWith updates error', () {
      const state = ScreenShareState.empty;
      final updated = state.copyWith(error: 'Something went wrong');
      expect(updated.error, 'Something went wrong');
      expect(updated.isScreenSharing, isFalse);
    });
  });

  group('ScreenShare notifier', () {
    test('setLiveKitScreenShareActive(true) sets isScreenSharing', () {
      final container = _container();
      final notifier = container.read(screenShareProvider.notifier);
      expect(container.read(screenShareProvider).isScreenSharing, isFalse);

      notifier.setLiveKitScreenShareActive(true);
      expect(container.read(screenShareProvider).isScreenSharing, isTrue);
      expect(container.read(screenShareProvider).error, isNull);
    });

    test('setLiveKitScreenShareActive(false) clears isScreenSharing', () {
      final container = _container();
      final notifier = container.read(screenShareProvider.notifier);
      notifier.setLiveKitScreenShareActive(true);
      notifier.setLiveKitScreenShareActive(false);
      expect(container.read(screenShareProvider).isScreenSharing, isFalse);
    });

    test('setLiveKitScreenShareActive clears any previous error', () {
      final container = _container();
      final notifier = container.read(screenShareProvider.notifier);
      notifier.setLiveKitScreenShareActive(true);
      expect(container.read(screenShareProvider).error, isNull);
    });

    test('stopScreenShare when not sharing is a no-op', () async {
      final container = _container();
      final notifier = container.read(screenShareProvider.notifier);
      // Should not throw
      await notifier.stopScreenShare();
      expect(container.read(screenShareProvider).isScreenSharing, isFalse);
    });
  });
}
