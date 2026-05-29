// Tests for [DeviceNamesNotifier] and the convenience [deviceNameProvider]
// family selector. Validates:
//   1. setLocal updates the in-memory map without a server round-trip
//      (used as the optimistic-update path in Settings > Devices).
//   2. deviceNameProvider returns the cached name when present.
//   3. deviceNameProvider returns null when the device is unknown so the
//      multi-device authority pill can fall back to "another device".

import 'package:echo_app/src/providers/device_name_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubDeviceNamesNotifier extends DeviceNamesNotifier {
  _StubDeviceNamesNotifier(this._seed);
  final Map<int, String> _seed;

  @override
  Future<Map<int, String>> build() async => _seed;
}

ProviderContainer _containerWith(Map<int, String> seed) {
  return ProviderContainer(
    overrides: [
      deviceNamesProvider.overrideWith(() => _StubDeviceNamesNotifier(seed)),
    ],
  );
}

void main() {
  group('DeviceNamesNotifier.setLocal', () {
    test('inserts a new device name into the cached map', () async {
      final container = _containerWith(const {0: 'MacBook Pro'});
      // Hydrate first.
      await container.read(deviceNamesProvider.future);

      container.read(deviceNamesProvider.notifier).setLocal(7, 'iPhone 15');

      final map = container.read(deviceNamesProvider).valueOrNull!;
      expect(map[0], 'MacBook Pro');
      expect(map[7], 'iPhone 15');
      container.dispose();
    });

    test('overwrites an existing entry (optimistic update)', () async {
      final container = _containerWith(const {3: 'Old Name'});
      await container.read(deviceNamesProvider.future);

      container.read(deviceNamesProvider.notifier).setLocal(3, 'Test Device A');

      final map = container.read(deviceNamesProvider).valueOrNull!;
      expect(map[3], 'Test Device A');
      container.dispose();
    });
  });

  group('deviceNameProvider selector', () {
    test('returns cached name when known', () async {
      final container = _containerWith(const {12: 'Office Laptop'});
      await container.read(deviceNamesProvider.future);

      expect(container.read(deviceNameProvider(12)), 'Office Laptop');
      container.dispose();
    });

    test('returns null when the device is not in the cached map', () async {
      final container = _containerWith(const {1: 'Linux'});
      await container.read(deviceNamesProvider.future);

      expect(container.read(deviceNameProvider(999)), isNull);
      container.dispose();
    });
  });
}
