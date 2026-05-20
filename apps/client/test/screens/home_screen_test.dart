// HomeScreen is the app's 832-LOC main shell. It transitively pulls in
// roughly two dozen Riverpod providers (auth, crypto, websocket, voice,
// chat, channels, contacts, conversations, push, tray, system-chrome,
// release-notes, etc.) plus GoRouter for navigation.  Mocking every leaf
// to the point of "this test verifies something real" would essentially
// reimplement HomeScreen in test doubles — the test would assert against
// its own scaffolding instead of the production code.
//
// What we CAN do in unit-test scope without that mess:
// - Pump the widget inside a minimal ProviderScope using the project-
//   standard `standardOverrides()` so the build path is exercised.
// - Use a tiny GoRouter so the embedded `context.go(...)` calls don't
//   crash on absence of a router.
// - Assert that the widget tree mounts without throwing.
//
// Anything deeper (sidebar resize, conversation selection, voice dock
// integration) is covered by the dedicated widget tests for those
// sub-components (channel_bar_test, voice_footer_test, conversation_panel_test,
// narrow_swipe_navigation_test, ...). Re-asserting their behaviour through
// HomeScreen would couple this test to UI organisation in a way that breaks
// on every cosmetic refactor.
//
// The single smoke test below is therefore intentionally narrow — its
// purpose is to keep the build path of HomeScreen green so a syntactic
// regression in this file is caught before it reaches CI.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/models/channel.dart';
import 'package:echo_app/src/providers/channels_provider.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/livekit_voice/livekit_voice_provider.dart';
import 'package:echo_app/src/providers/privacy_provider.dart';
import 'package:echo_app/src/providers/release_notes_provider.dart';
import 'package:echo_app/src/providers/update_provider.dart';
// ignore: unused_import — kept for documentation of intent: release_notes_provider
// is overridden via a fake AsyncNotifier below.
import 'package:echo_app/src/screens/home_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

class _FakeChat extends Chat {
  @override
  ChatState build() => const ChatState();
}

class _FakeChannels extends Channels {
  @override
  ChannelsState build() => const ChannelsState(
    channelsByConversation: <String, List<GroupChannel>>{},
  );

  @override
  Future<void> loadChannels(String conversationId) async {}
}

class _FakeUpdate extends Update {
  @override
  UpdateState build() => const UpdateState();

  @override
  Future<void> check({bool force = false}) async {}
}

class _FakePrivacy extends Privacy {
  @override
  PrivacyState build() => const PrivacyState();

  @override
  Future<void> load() async {}
}

class _FakeReleaseNotes extends ReleaseNotesNotifier {
  @override
  Future<ReleaseNotesView?> build() async => null;
}

class _FakeLiveKit extends LiveKitVoiceNotifier {
  @override
  LiveKitVoiceState build() => LiveKitVoiceState.empty;

  @override
  Future<void> leaveChannel() async {}

  @override
  Future<void> joinChannel({
    required String conversationId,
    required String channelId,
    bool startMuted = false,
  }) async {}
}

GoRouter _router() => GoRouter(
  initialLocation: '/home',
  routes: [
    GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
    GoRoute(
      path: '/login',
      builder: (_, _) => const Scaffold(body: Text('LOGIN')),
    ),
  ],
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('HomeScreen build path mounts without throwing', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...standardOverrides(),
          chatProvider.overrideWith(_FakeChat.new),
          channelsProvider.overrideWith(_FakeChannels.new),
          updateProvider.overrideWith(_FakeUpdate.new),
          privacyProvider.overrideWith(_FakePrivacy.new),
          livekitVoiceProvider.overrideWith(_FakeLiveKit.new),
          releaseNotesProvider.overrideWith(_FakeReleaseNotes.new),
        ],
        child: MaterialApp.router(
          theme: EchoTheme.darkTheme,
          darkTheme: EchoTheme.darkTheme,
          themeMode: ThemeMode.dark,
          routerConfig: _router(),
        ),
      ),
    );
    // First frame.
    await tester.pump();
    // Let post-frame `_initData()` fire and the awaited mock futures
    // resolve. We deliberately avoid pumpAndSettle: voice/network
    // pollers used by the live notifiers can keep the frame-loop dirty
    // forever in test mode.
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(HomeScreen), findsOneWidget);
  });
}
