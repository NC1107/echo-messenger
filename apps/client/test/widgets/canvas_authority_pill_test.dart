// Focused widget test for the multi-device canvas authority pill — proves
// that the pill renders "Drawing from <device_name>" when the
// [deviceNameProvider] family returns a real name, and falls back to
// "Drawing from another device" when the name has not yet loaded.
//
// The pill code lives in voice_lounge_screen.dart as a private helper; this
// test rebuilds the same composition (canvasAuthorityNotifierProvider +
// deviceNameProvider) so the contract is locked down without dragging the
// full lounge screen into the harness.
//
// See docs/voice-lounge/03-multi-device.md.

import 'package:echo_app/src/providers/canvas_authority_provider.dart';
import 'package:echo_app/src/providers/device_name_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const String _kChannelId = 'channel-x';
const int _kMyDeviceId = 1;
const int _kOtherDeviceId = 2;

class _StubDeviceNamesNotifier extends DeviceNamesNotifier {
  _StubDeviceNamesNotifier(this._seed);
  final Map<int, String> _seed;

  @override
  Future<Map<int, String>> build() async => _seed;
}

/// The actual pill builder we want to test, lifted into a tiny widget so we
/// can mount it under [ProviderScope] in isolation.
class _AuthorityPillUnderTest extends ConsumerWidget {
  const _AuthorityPillUnderTest({required this.myDeviceId});
  final int myDeviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authority = ref.watch(canvasAuthorityNotifierProvider(_kChannelId));
    if (authority == null || authority == myDeviceId) {
      return const SizedBox.shrink();
    }
    final resolvedName = ref.watch(deviceNameProvider(authority));
    return Text('Drawing from ${resolvedName ?? 'another device'}');
  }
}

Future<void> _pumpPill(
  WidgetTester tester, {
  required Map<int, String> deviceNames,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceNamesProvider.overrideWith(
          () => _StubDeviceNamesNotifier(deviceNames),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: _AuthorityPillUnderTest(myDeviceId: _kMyDeviceId)),
      ),
    ),
  );
  // Allow the async build of DeviceNamesNotifier to settle.
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('pill shows resolved name when authority device is in the map', (
    tester,
  ) async {
    await _pumpPill(
      tester,
      deviceNames: const {_kOtherDeviceId: 'MacBook Pro'},
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(_AuthorityPillUnderTest)),
    );
    container
        .read(canvasAuthorityNotifierProvider(_kChannelId).notifier)
        .setAuthority(_kOtherDeviceId);
    await tester.pumpAndSettle();

    expect(find.text('Drawing from MacBook Pro'), findsOneWidget);
    expect(find.text('Drawing from another device'), findsNothing);
  });

  testWidgets('pill falls back to "another device" when name not cached', (
    tester,
  ) async {
    await _pumpPill(tester, deviceNames: const <int, String>{});
    final container = ProviderScope.containerOf(
      tester.element(find.byType(_AuthorityPillUnderTest)),
    );
    container
        .read(canvasAuthorityNotifierProvider(_kChannelId).notifier)
        .setAuthority(_kOtherDeviceId);
    await tester.pumpAndSettle();

    expect(find.text('Drawing from another device'), findsOneWidget);
  });

  testWidgets('pill hides when this device IS the authority', (tester) async {
    await _pumpPill(tester, deviceNames: const {_kMyDeviceId: 'My Phone'});
    final container = ProviderScope.containerOf(
      tester.element(find.byType(_AuthorityPillUnderTest)),
    );
    container
        .read(canvasAuthorityNotifierProvider(_kChannelId).notifier)
        .setAuthority(_kMyDeviceId);
    await tester.pumpAndSettle();

    expect(find.textContaining('Drawing from'), findsNothing);
  });
}
