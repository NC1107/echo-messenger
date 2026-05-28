// Widget tests for the voice-lounge floating dock — the primary AV control
// surface during a call.
//
// The dock fans out to four notifiers (livekitVoice, voiceSettings,
// screenShare, channels) plus a handful of parent callbacks. We override
// the notifiers with spies that record calls but never touch real LiveKit
// or SharedPreferences. The non-mockable bits — actual screen-share start
// (opens a desktop picker on Linux test hosts) and camera/mic toggling
// against a real LiveKit Room — are out of reach for unit tests; we
// exercise the UI state and the read-side state-driven branches instead.
//
// What's covered: button presence, icon-reflects-state for mic / camera /
// screenshare / deafen / spotlight, callback fan-out for the parent-owned
// toggles (drawing, spotlight, submenus), provider mutation for mic mute,
// deafen, and leave (channels + LiveKit teardown).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/channels_provider.dart';
import 'package:echo_app/src/providers/livekit_voice/livekit_voice_provider.dart';
import 'package:echo_app/src/providers/screen_share_provider.dart';
import 'package:echo_app/src/providers/voice_settings_provider.dart';
import 'package:echo_app/src/screens/voice_lounge/floating_dock.dart';
import 'package:echo_app/src/screens/voice_lounge/lounge_constants.dart';

import '../../helpers/pump_app.dart';

// ---------------------------------------------------------------------------
// Spies
// ---------------------------------------------------------------------------

class _FakeLiveKitNotifier extends LiveKitVoiceNotifier {
  _FakeLiveKitNotifier({LiveKitVoiceState? initial}) : _initial = initial;

  final LiveKitVoiceState? _initial;

  int setCaptureCalls = 0;
  bool? lastCaptureEnabled;

  int setDeafenedCalls = 0;
  bool? lastDeafened;

  int toggleVideoCalls = 0;

  int setScreenShareCalls = 0;
  bool? lastScreenShareEnabled;

  int leaveChannelCalls = 0;

  @override
  LiveKitVoiceState build() => _initial ?? LiveKitVoiceState.empty;

  @override
  void setCaptureEnabled(bool enabled) {
    setCaptureCalls++;
    lastCaptureEnabled = enabled;
    state = state.copyWith(isCaptureEnabled: enabled);
  }

  @override
  Future<void> setDeafened(bool deafened) async {
    setDeafenedCalls++;
    lastDeafened = deafened;
    state = state.copyWith(isDeafened: deafened);
  }

  @override
  Future<void> toggleVideo() async {
    toggleVideoCalls++;
    state = state.copyWith(isVideoEnabled: !state.isVideoEnabled);
  }

  @override
  Future<bool> setScreenShareEnabled(bool enabled, {String? sourceId}) async {
    setScreenShareCalls++;
    lastScreenShareEnabled = enabled;
    return true;
  }

  @override
  Future<void> leaveChannel() async {
    leaveChannelCalls++;
    state = LiveKitVoiceState.empty;
  }
}

class _FakeVoiceSettings extends VoiceSettings {
  _FakeVoiceSettings({VoiceSettingsState? initial}) : _initial = initial;

  final VoiceSettingsState? _initial;

  int setSelfMutedCalls = 0;
  bool? lastSelfMuted;

  int setSelfDeafenedCalls = 0;
  bool? lastSelfDeafened;

  @override
  VoiceSettingsState build() => _initial ?? const VoiceSettingsState();

  @override
  Future<void> setSelfMuted(bool value) async {
    setSelfMutedCalls++;
    lastSelfMuted = value;
    state = state.copyWith(selfMuted: value);
  }

  @override
  Future<void> setSelfDeafened(bool value) async {
    setSelfDeafenedCalls++;
    lastSelfDeafened = value;
    state = state.copyWith(selfDeafened: value);
  }
}

class _FakeScreenShare extends ScreenShare {
  _FakeScreenShare({ScreenShareState? initial}) : _initial = initial;

  final ScreenShareState? _initial;

  int setLiveKitScreenShareCalls = 0;
  bool? lastSetLiveKitActive;

  @override
  ScreenShareState build() => _initial ?? ScreenShareState.empty;

  @override
  void setLiveKitScreenShareActive(bool active) {
    setLiveKitScreenShareCalls++;
    lastSetLiveKitActive = active;
    state = state.copyWith(isScreenSharing: active);
  }
}

class _FakeChannelsNotifier extends Channels {
  int leaveVoiceCalls = 0;
  String? lastLeaveConversationId;
  String? lastLeaveChannelId;

  @override
  ChannelsState build() => const ChannelsState();

  @override
  Future<bool> leaveVoiceChannel(
    String conversationId,
    String channelId,
  ) async {
    leaveVoiceCalls++;
    lastLeaveConversationId = conversationId;
    lastLeaveChannelId = channelId;
    return true;
  }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class _DockHarness extends StatefulWidget {
  const _DockHarness({
    required this.voiceState,
    required this.voiceSettings,
    required this.screenShare,
    this.spotlightMode = false,
    this.onToggleSpotlight,
    this.onToggleDrawing,
    this.onToggleSubmenu,
  });

  final LiveKitVoiceState voiceState;
  final VoiceSettingsState voiceSettings;
  final ScreenShareState screenShare;
  final bool spotlightMode;
  final VoidCallback? onToggleSpotlight;
  final VoidCallback? onToggleDrawing;
  final ValueChanged<DockSubmenu>? onToggleSubmenu;

  @override
  State<_DockHarness> createState() => _DockHarnessState();
}

class _DockHarnessState extends State<_DockHarness> {
  final _micLink = LayerLink();
  final _cameraLink = LayerLink();
  final _screenLink = LayerLink();
  final _drawLink = LayerLink();

  @override
  Widget build(BuildContext context) {
    return FloatingDock(
      voiceState: widget.voiceState,
      voiceSettings: widget.voiceSettings,
      screenShare: widget.screenShare,
      conversationId: 'conv-1',
      channelId: 'voice-1',
      isDrawing: false,
      onToggleDrawing: widget.onToggleDrawing ?? () {},
      activeSubmenu: null,
      onToggleSubmenu: widget.onToggleSubmenu ?? (_) {},
      micLayerLink: _micLink,
      cameraLayerLink: _cameraLink,
      screenShareLayerLink: _screenLink,
      drawingToolsLayerLink: _drawLink,
      spotlightMode: widget.spotlightMode,
      onToggleSpotlight: widget.onToggleSpotlight ?? () {},
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

List<Override> _overrides({
  _FakeLiveKitNotifier? livekit,
  _FakeVoiceSettings? voiceSettings,
  _FakeScreenShare? screenShare,
  _FakeChannelsNotifier? channels,
}) {
  return [
    livekitVoiceProvider.overrideWith(() => livekit ?? _FakeLiveKitNotifier()),
    voiceSettingsProvider.overrideWith(
      () => voiceSettings ?? _FakeVoiceSettings(),
    ),
    screenShareProvider.overrideWith(() => screenShare ?? _FakeScreenShare()),
    channelsProvider.overrideWith(() => channels ?? _FakeChannelsNotifier()),
  ];
}

void main() {
  group('FloatingDock layout', () {
    testWidgets(
      'renders mic, deafen, camera, screen-share, draw, spotlight, leave',
      (tester) async {
        await tester.pumpApp(
          const _DockHarness(
            voiceState: LiveKitVoiceState.empty,
            voiceSettings: VoiceSettingsState(),
            screenShare: ScreenShareState.empty,
          ),
          overrides: _overrides(),
        );
        await tester.pump();

        // Mic + deafen + camera + screen-share + draw + spotlight + leave.
        expect(find.byIcon(Icons.mic), findsOneWidget);
        expect(find.byIcon(Icons.headset), findsOneWidget);
        expect(find.byIcon(Icons.videocam_off), findsOneWidget);
        expect(find.byIcon(Icons.screen_share), findsOneWidget);
        expect(find.byIcon(Icons.edit), findsOneWidget);
        // Spotlight defaults to OFF -> Icons.people ("switch TO spotlight").
        expect(find.byIcon(Icons.people), findsOneWidget);
        expect(find.byIcon(Icons.call_end), findsOneWidget);
      },
    );

    testWidgets('omits draw button when spotlight mode is on', (tester) async {
      await tester.pumpApp(
        const _DockHarness(
          voiceState: LiveKitVoiceState.empty,
          voiceSettings: VoiceSettingsState(),
          screenShare: ScreenShareState.empty,
          spotlightMode: true,
        ),
        overrides: _overrides(),
      );
      await tester.pump();

      // Draw is hidden in spotlight mode, but the rest of the dock is intact.
      expect(find.byIcon(Icons.edit), findsNothing);
      expect(find.byIcon(Icons.call_end), findsOneWidget);
      // Spotlight ON -> Icons.grid_view ("switch back to canvas").
      expect(find.byIcon(Icons.grid_view), findsOneWidget);
    });
  });

  group('FloatingDock icon reflects state', () {
    testWidgets('mic icon flips to mic_off when self-muted', (tester) async {
      await tester.pumpApp(
        const _DockHarness(
          voiceState: LiveKitVoiceState.empty,
          voiceSettings: VoiceSettingsState(selfMuted: true),
          screenShare: ScreenShareState.empty,
        ),
        overrides: _overrides(),
      );
      await tester.pump();

      expect(find.byIcon(Icons.mic_off), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsNothing);
    });

    testWidgets('headset icon flips to headset_off when deafened', (
      tester,
    ) async {
      await tester.pumpApp(
        const _DockHarness(
          voiceState: LiveKitVoiceState.empty,
          voiceSettings: VoiceSettingsState(selfDeafened: true),
          screenShare: ScreenShareState.empty,
        ),
        overrides: _overrides(),
      );
      await tester.pump();

      expect(find.byIcon(Icons.headset_off), findsOneWidget);
      expect(find.byIcon(Icons.headset), findsNothing);
    });

    testWidgets('camera icon shows videocam when camera is enabled', (
      tester,
    ) async {
      await tester.pumpApp(
        const _DockHarness(
          voiceState: LiveKitVoiceState(isVideoEnabled: true),
          voiceSettings: VoiceSettingsState(),
          screenShare: ScreenShareState.empty,
        ),
        overrides: _overrides(),
      );
      await tester.pump();

      expect(find.byIcon(Icons.videocam), findsOneWidget);
      expect(find.byIcon(Icons.videocam_off), findsNothing);
    });

    testWidgets(
      'screen-share icon flips to stop_screen_share when already sharing',
      (tester) async {
        await tester.pumpApp(
          const _DockHarness(
            voiceState: LiveKitVoiceState.empty,
            voiceSettings: VoiceSettingsState(),
            screenShare: ScreenShareState(isScreenSharing: true),
          ),
          overrides: _overrides(),
        );
        await tester.pump();

        expect(find.byIcon(Icons.stop_screen_share), findsOneWidget);
        expect(find.byIcon(Icons.screen_share), findsNothing);
      },
    );
  });

  group('FloatingDock interactions', () {
    testWidgets('tapping mic toggles self-mute and pushes capture state', (
      tester,
    ) async {
      final livekit = _FakeLiveKitNotifier();
      final settings = _FakeVoiceSettings();

      await tester.pumpApp(
        const _DockHarness(
          voiceState: LiveKitVoiceState.empty,
          voiceSettings: VoiceSettingsState(),
          screenShare: ScreenShareState.empty,
        ),
        overrides: _overrides(livekit: livekit, voiceSettings: settings),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.mic));
      await tester.pumpAndSettle();

      expect(settings.setSelfMutedCalls, 1);
      expect(settings.lastSelfMuted, isTrue);
      // Mute -> capture off.
      expect(livekit.setCaptureCalls, 1);
      expect(livekit.lastCaptureEnabled, isFalse);
    });

    testWidgets('tapping mic while muted unmutes and re-enables capture', (
      tester,
    ) async {
      final livekit = _FakeLiveKitNotifier();
      final settings = _FakeVoiceSettings(
        initial: const VoiceSettingsState(selfMuted: true),
      );

      await tester.pumpApp(
        const _DockHarness(
          voiceState: LiveKitVoiceState.empty,
          voiceSettings: VoiceSettingsState(selfMuted: true),
          screenShare: ScreenShareState.empty,
        ),
        overrides: _overrides(livekit: livekit, voiceSettings: settings),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.mic_off));
      await tester.pumpAndSettle();

      expect(settings.lastSelfMuted, isFalse);
      expect(livekit.lastCaptureEnabled, isTrue);
    });

    testWidgets('tapping deafen toggles self-deafen on both providers', (
      tester,
    ) async {
      final livekit = _FakeLiveKitNotifier();
      final settings = _FakeVoiceSettings();

      await tester.pumpApp(
        const _DockHarness(
          voiceState: LiveKitVoiceState.empty,
          voiceSettings: VoiceSettingsState(),
          screenShare: ScreenShareState.empty,
        ),
        overrides: _overrides(livekit: livekit, voiceSettings: settings),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.headset));
      await tester.pumpAndSettle();

      expect(settings.setSelfDeafenedCalls, 1);
      expect(settings.lastSelfDeafened, isTrue);
      expect(livekit.setDeafenedCalls, 1);
      expect(livekit.lastDeafened, isTrue);
    });

    testWidgets('tapping camera fires toggleVideo on the LiveKit notifier', (
      tester,
    ) async {
      final livekit = _FakeLiveKitNotifier();

      await tester.pumpApp(
        const _DockHarness(
          voiceState: LiveKitVoiceState.empty,
          voiceSettings: VoiceSettingsState(),
          screenShare: ScreenShareState.empty,
        ),
        overrides: _overrides(livekit: livekit),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.videocam_off));
      await tester.pumpAndSettle();

      expect(livekit.toggleVideoCalls, 1);
    });

    testWidgets(
      'tapping stop-screen-share when already sharing tears the share down',
      (tester) async {
        // The stop path is fully reachable from a unit test (it calls
        // setScreenShareEnabled(false) + setLiveKitScreenShareActive(false)
        // without needing a real Room). The start path opens a desktop
        // source-picker dialog on Linux/macOS/Windows hosts and isn't
        // reachable without a real LiveKit room — that path is covered by
        // screen_share_actions_test.dart and integration tests.
        final livekit = _FakeLiveKitNotifier();
        final screenShare = _FakeScreenShare(
          initial: const ScreenShareState(isScreenSharing: true),
        );

        await tester.pumpApp(
          const _DockHarness(
            voiceState: LiveKitVoiceState.empty,
            voiceSettings: VoiceSettingsState(),
            screenShare: ScreenShareState(isScreenSharing: true),
          ),
          overrides: _overrides(livekit: livekit, screenShare: screenShare),
        );
        await tester.pump();

        await tester.tap(find.byIcon(Icons.stop_screen_share));
        await tester.pumpAndSettle();

        expect(livekit.setScreenShareCalls, 1);
        expect(livekit.lastScreenShareEnabled, isFalse);
        expect(screenShare.setLiveKitScreenShareCalls, 1);
        expect(screenShare.lastSetLiveKitActive, isFalse);
      },
    );

    testWidgets('tapping leave drops the channel and tears LiveKit down', (
      tester,
    ) async {
      final livekit = _FakeLiveKitNotifier();
      final channels = _FakeChannelsNotifier();

      await tester.pumpApp(
        const _DockHarness(
          voiceState: LiveKitVoiceState.empty,
          voiceSettings: VoiceSettingsState(),
          screenShare: ScreenShareState.empty,
        ),
        overrides: _overrides(livekit: livekit, channels: channels),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.call_end));
      await tester.pumpAndSettle();

      expect(channels.leaveVoiceCalls, 1);
      expect(channels.lastLeaveConversationId, 'conv-1');
      expect(channels.lastLeaveChannelId, 'voice-1');
      expect(livekit.leaveChannelCalls, 1);
    });

    testWidgets(
      'rapid double-tap on leave calls leaveChannel exactly once, no crash',
      (tester) async {
        // Simulate the user mashing the leave button before the first
        // disconnect resolves.  leaveChannel is async; we complete the pump
        // after both taps so the test verifies the idempotency guard.
        final livekit = _FakeLiveKitNotifier();
        final channels = _FakeChannelsNotifier();

        await tester.pumpApp(
          const _DockHarness(
            voiceState: LiveKitVoiceState.empty,
            voiceSettings: VoiceSettingsState(),
            screenShare: ScreenShareState.empty,
          ),
          overrides: _overrides(livekit: livekit, channels: channels),
        );
        await tester.pump();

        // First tap — starts the leave sequence.
        await tester.tap(find.byIcon(Icons.call_end));
        // Second tap fires BEFORE the first async sequence drains.
        // After the first tap, _isLeaving=true so the button is disabled;
        // the second tap must be a no-op.
        await tester.tap(find.byIcon(Icons.call_end));
        // Let both async tasks complete.
        await tester.pumpAndSettle();

        // leaveChannel must have been called exactly once, not twice.
        expect(livekit.leaveChannelCalls, 1);
        expect(channels.leaveVoiceCalls, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'leaving while screen-sharing also stops the share before tearing down',
      (tester) async {
        final livekit = _FakeLiveKitNotifier();
        final channels = _FakeChannelsNotifier();
        final screenShare = _FakeScreenShare(
          initial: const ScreenShareState(isScreenSharing: true),
        );

        await tester.pumpApp(
          const _DockHarness(
            voiceState: LiveKitVoiceState.empty,
            voiceSettings: VoiceSettingsState(),
            screenShare: ScreenShareState(isScreenSharing: true),
          ),
          overrides: _overrides(
            livekit: livekit,
            channels: channels,
            screenShare: screenShare,
          ),
        );
        await tester.pump();

        await tester.tap(find.byIcon(Icons.call_end));
        await tester.pumpAndSettle();

        // Screen share was disabled prior to leaving the room.
        expect(livekit.setScreenShareCalls, 1);
        expect(livekit.lastScreenShareEnabled, isFalse);
        expect(screenShare.setLiveKitScreenShareCalls, 1);
        expect(screenShare.lastSetLiveKitActive, isFalse);
        // And the actual leave still fires.
        expect(channels.leaveVoiceCalls, 1);
        expect(livekit.leaveChannelCalls, 1);
      },
    );

    testWidgets('tapping the draw button fires the parent onToggleDrawing', (
      tester,
    ) async {
      var drawCalls = 0;

      await tester.pumpApp(
        _DockHarness(
          voiceState: LiveKitVoiceState.empty,
          voiceSettings: const VoiceSettingsState(),
          screenShare: ScreenShareState.empty,
          onToggleDrawing: () => drawCalls++,
        ),
        overrides: _overrides(),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();

      expect(drawCalls, 1);
    });

    testWidgets(
      'tapping the spotlight button fires the parent onToggleSpotlight',
      (tester) async {
        var spotlightCalls = 0;

        await tester.pumpApp(
          _DockHarness(
            voiceState: LiveKitVoiceState.empty,
            voiceSettings: const VoiceSettingsState(),
            screenShare: ScreenShareState.empty,
            onToggleSpotlight: () => spotlightCalls++,
          ),
          overrides: _overrides(),
        );
        await tester.pump();

        // Spotlight off -> shows people icon.
        await tester.tap(find.byIcon(Icons.people));
        await tester.pumpAndSettle();

        expect(spotlightCalls, 1);
      },
    );

    testWidgets('tapping the mic submenu chevron fires onToggleSubmenu(mic)', (
      tester,
    ) async {
      DockSubmenu? lastSubmenu;
      var submenuCalls = 0;

      await tester.pumpApp(
        _DockHarness(
          voiceState: LiveKitVoiceState.empty,
          voiceSettings: const VoiceSettingsState(),
          screenShare: ScreenShareState.empty,
          onToggleSubmenu: (submenu) {
            submenuCalls++;
            lastSubmenu = submenu;
          },
        ),
        overrides: _overrides(),
      );
      await tester.pump();

      // Each DockButtonWithSubmenu adds one chevron. Mic is the first, so
      // the first expand_more in widget order belongs to it.
      await tester.tap(find.byIcon(Icons.expand_more).first);
      await tester.pumpAndSettle();

      expect(submenuCalls, 1);
      expect(lastSubmenu, DockSubmenu.mic);
    });
  });
}
