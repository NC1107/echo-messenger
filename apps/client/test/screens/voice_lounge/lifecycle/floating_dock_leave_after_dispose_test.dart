// Regression: `_handleLeave` must complete without touching `ref` after the
// dock has been disposed. Repro pattern: user taps the leave button, the
// `await livekit.leaveChannel()` yields, parent HomeScreen rebuilds and
// replaces the lounge with the chat content (or the foreground-service
// ACTION_LEAVE races the UI), the dock's ConsumerState is disposed, then the
// awaited future completes. The dock must not `ref.read` or `setState` after
// dispose → `StateError: Cannot use "ref" after the widget was disposed`.
//
// Fix: cache notifier handles before the await (captured references, not
// `ref.read`) and guard the only post-await `setState` (VL-10 failure reset)
// with `mounted`. This test parks `leaveChannel` on a gate, disposes the dock
// mid-flight, then completes the leave and asserts no error was raised.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/livekit_voice/livekit_voice_provider.dart';
import 'package:echo_app/src/providers/screen_share_provider.dart';
import 'package:echo_app/src/providers/voice_settings_provider.dart';
import 'package:echo_app/src/screens/voice_lounge/floating_dock.dart';

import '../../../helpers/pump_app.dart';

class _GatedLiveKitNotifier extends LiveKitVoiceNotifier {
  /// Held until [gate] is completed so the leave button's await genuinely
  /// yields and we can dispose the dock mid-flight.
  final Completer<void> gate = Completer<void>();
  int leaveChannelCalls = 0;

  @override
  LiveKitVoiceState build() => LiveKitVoiceState.empty;

  @override
  Future<void> leaveChannel() async {
    leaveChannelCalls++;
    await gate.future;
  }
}

class _FakeVoiceSettings extends VoiceSettings {
  @override
  VoiceSettingsState build() => const VoiceSettingsState();
}

class _FakeScreenShare extends ScreenShare {
  @override
  ScreenShareState build() => ScreenShareState.empty;
}

class _DockHost extends StatefulWidget {
  const _DockHost({super.key});

  @override
  State<_DockHost> createState() => _DockHostState();
}

class _DockHostState extends State<_DockHost> {
  bool _showDock = true;
  final _micLink = LayerLink();
  final _camLink = LayerLink();
  final _shareLink = LayerLink();
  final _drawLink = LayerLink();

  void hide() => setState(() => _showDock = false);

  @override
  Widget build(BuildContext context) {
    if (!_showDock) return const SizedBox.shrink();
    return FloatingDock(
      voiceState: LiveKitVoiceState.empty,
      voiceSettings: const VoiceSettingsState(),
      screenShare: ScreenShareState.empty,
      conversationId: 'conv-1',
      channelId: 'voice-1',
      isDrawing: false,
      onToggleDrawing: () {},
      activeSubmenu: null,
      onToggleSubmenu: (_) {},
      micLayerLink: _micLink,
      cameraLayerLink: _camLink,
      screenShareLayerLink: _shareLink,
      drawingToolsLayerLink: _drawLink,
      spotlightMode: false,
      onToggleSpotlight: () {},
    );
  }
}

void main() {
  testWidgets('leave button does not throw if dock is disposed mid-await', (
    tester,
  ) async {
    final livekit = _GatedLiveKitNotifier();

    final hostKey = GlobalKey<_DockHostState>();

    await tester.pumpApp(
      _DockHost(key: hostKey),
      overrides: [
        livekitVoiceProvider.overrideWith(() => livekit),
        voiceSettingsProvider.overrideWith(() => _FakeVoiceSettings()),
        screenShareProvider.overrideWith(() => _FakeScreenShare()),
      ],
    );
    await tester.pump();

    // Tap leave — `_handleLeave` runs, captures the notifiers, then parks on
    // `await livekit.leaveChannel()` (held by the gate).
    await tester.tap(find.byIcon(Icons.call_end));
    await tester.pump();
    expect(livekit.leaveChannelCalls, 1);

    // Dispose the dock while the leave is still in flight.
    hostKey.currentState!.hide();
    await tester.pump();

    // Release the gate so the rest of `_handleLeave` runs against a disposed
    // ConsumerState. The dock captured `livekit` before the await and guards
    // its only post-await setState with `mounted`, so nothing throws.
    livekit.gate.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
