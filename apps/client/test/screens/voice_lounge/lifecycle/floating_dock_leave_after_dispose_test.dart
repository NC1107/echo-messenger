// Regression: `_handleLeave` must complete without touching `ref` after the
// dock has been disposed. Repro pattern: user taps the leave button, the
// first `await` (channels.leaveVoiceChannel) yields, parent HomeScreen
// rebuilds and replaces the lounge with the chat content (or the
// foreground-service ACTION_LEAVE races the UI), the dock's ConsumerState
// is disposed, then the awaited future completes and tries to `ref.read`
// the LiveKit notifier → `StateError: Cannot use "ref" after the widget
// was disposed`.
//
// Fix: cache notifier handles before the first await so the post-dispose
// path uses captured references instead of `ref.read`. This test races a
// long-running leaveVoiceChannel against `pumpWidget(SizedBox.shrink())`
// to disposing the dock, then completes the leave and asserts no error
// was raised.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/channels_provider.dart';
import 'package:echo_app/src/providers/livekit_voice/livekit_voice_provider.dart';
import 'package:echo_app/src/providers/screen_share_provider.dart';
import 'package:echo_app/src/providers/voice_settings_provider.dart';
import 'package:echo_app/src/screens/voice_lounge/floating_dock.dart';

import '../../../helpers/pump_app.dart';

class _SlowChannelsNotifier extends Channels {
  /// Held until [release] is called so the leave button's first await
  /// genuinely yields and we can dispose the dock mid-flight.
  final Completer<bool> gate = Completer<bool>();
  int leaveVoiceCalls = 0;

  @override
  ChannelsState build() => const ChannelsState();

  @override
  Future<bool> leaveVoiceChannel(String conversationId, String channelId) {
    leaveVoiceCalls++;
    return gate.future;
  }
}

class _CountingLiveKitNotifier extends LiveKitVoiceNotifier {
  int leaveChannelCalls = 0;

  @override
  LiveKitVoiceState build() => LiveKitVoiceState.empty;

  @override
  Future<void> leaveChannel() async {
    leaveChannelCalls++;
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
    final channels = _SlowChannelsNotifier();
    final livekit = _CountingLiveKitNotifier();

    final hostKey = GlobalKey<_DockHostState>();

    await tester.pumpApp(
      _DockHost(key: hostKey),
      overrides: [
        channelsProvider.overrideWith(() => channels),
        livekitVoiceProvider.overrideWith(() => livekit),
        voiceSettingsProvider.overrideWith(() => _FakeVoiceSettings()),
        screenShareProvider.overrideWith(() => _FakeScreenShare()),
      ],
    );
    await tester.pump();

    // Tap leave — `_handleLeave` runs, hits `channels.leaveVoiceChannel`
    // and parks on `_SlowChannelsNotifier.gate.future`.
    await tester.tap(find.byIcon(Icons.call_end));
    await tester.pump();
    expect(channels.leaveVoiceCalls, 1);

    // Dispose the dock while the leave is still in flight.
    hostKey.currentState!.hide();
    await tester.pump();

    // Release the gate so the rest of `_handleLeave` runs against a
    // disposed ConsumerState. Without the fix, the subsequent
    // `ref.read(livekitVoiceProvider.notifier).leaveChannel()` throws
    // `StateError: Cannot use "ref"`.
    channels.gate.complete(true);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // leaveChannel should still complete via the captured notifier.
    expect(livekit.leaveChannelCalls, 1);
  });
}
