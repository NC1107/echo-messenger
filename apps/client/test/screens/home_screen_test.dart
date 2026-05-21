// HomeScreen is the app's main shell. After commit 8fe88cd9 it was split
// from a single 832-LOC file into a 242-LOC parent plus six mixin parts:
// lifecycle, actions, listeners, desktop_layout, wide_layout, narrow_layout.
//
// HomeScreen still transitively pulls in ~24 Riverpod providers (auth,
// crypto, websocket, voice, chat, channels, contacts, conversations,
// privacy, update, release-notes, server-url, …) plus GoRouter for
// navigation and a tray service / system-chrome side effect.  Mocking
// every leaf to the point of "this test verifies something real" would
// essentially reimplement HomeScreen in test doubles, so we don't try
// to test the lifecycle or listeners parts in isolation.
//
// What we CAN cover after the split:
//
// - **wide_layout** (600–899 px): `_buildWideLayout` produces a 300 px
//   sidebar + 1 px divider + content area with a single `AppTitleBar`.
//   With no conversation selected the right panel is the empty state.
//
// - **narrow_layout** (< 600 px): `_buildNarrowLayout` produces a
//   bottom tab bar with four tabs labelled Chats / Discover / Contacts /
//   Settings (each rendered with a `Semantics(label: '<x> tab')` node).
//   Tapping a non-Chats tab swaps the body.
//
// - **desktop_layout** (≥ 900 px): `_buildDesktopLayout` produces
//   `AppTitleBar` + animated sidebar + a draggable resize handle
//   (`Semantics(label: 'Resize sidebar')`) + content area.
//
// What we DO NOT cover, and why:
//
// - **lifecycle**: `_initData` orchestrates crypto init, WS connect,
//   conversation load, contact load, privacy load, update check, what's-new
//   modal, tray init, and the first-login server-notice dialog.  Each step
//   is awaited; mocking them realistically requires fakes for every
//   dependency.  Pumping the shell already exercises the post-frame
//   callback through the existing stubs — re-asserting it would just
//   assert against our own fakes.
//
// - **listeners**: `_listenForErrors` reacts to provider deltas (error
//   strings, voice disconnects, crypto key regenerations).  Driving those
//   transitions through the real notifiers in a test creates timing-
//   fragile sequences that mostly verify Riverpod itself.
//
// - **edge-swipe gesture** in narrow_layout: relies on an
//   `AnimationController` + global drag positions + post-frame state.
//   Drag synthesis through `WidgetTester` is flaky for this kind of
//   progress-driven UI; not worth the regression risk.

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
import 'package:echo_app/src/screens/home_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/window_chrome.dart';

import '../helpers/mock_providers.dart';

// ---------------------------------------------------------------------------
// Per-test fake notifiers.  Each one stubs a provider that HomeScreen reads
// directly or that one of the parts (`lifecycle`, `narrow_layout`,
// `desktop_layout`, `wide_layout`) reads on every build.  These are kept
// minimal — only the methods called during build + post-frame need to be
// overridden so we don't trip real I/O in tests.
// ---------------------------------------------------------------------------

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

// `standardOverrides()` covers auth, server URL, conversations, contacts,
// websocket and crypto.  HomeScreen also reads chat, channels, update,
// privacy, livekit voice and release-notes providers from one or more of
// its parts — these are appended below in each test.
List<Override> _homeOverrides() => [
  ...standardOverrides(),
  // chat: read by `_logout` (actions.dart) and indirectly by ChatPanel.
  chatProvider.overrideWith(_FakeChat.new),
  // channels: read whenever a group conversation panel renders.
  channelsProvider.overrideWith(_FakeChannels.new),
  // update: read by both narrow tab-bar (Settings update dot) and desktop
  // collapsed-sidebar settings icon.  Lifecycle part also calls check().
  updateProvider.overrideWith(_FakeUpdate.new),
  // privacy: lifecycle part awaits privacy.load() in _initData.
  privacyProvider.overrideWith(_FakePrivacy.new),
  // voice: every layout watches voiceRtcProvider (= livekitVoiceProvider)
  // to decide whether to show the lounge.
  livekitVoiceProvider.overrideWith(_FakeLiveKit.new),
  // release-notes: lifecycle part awaits releaseNotesProvider.future before
  // maybe-showing the What's New modal.  Returning null short-circuits.
  releaseNotesProvider.overrideWith(_FakeReleaseNotes.new),
];

/// Finds the `Semantics` widget whose `properties.label` equals [label].
/// We use a widget predicate rather than `find.bySemanticsLabel(...)`
/// because the tab-bar `Semantics` declarations sit under InkWell + other
/// inner Semantics nodes; `bySemanticsLabel` walks render-object semantics
/// configs and the merged tree elides the label in this case, returning
/// zero matches even though the Semantics widget itself is present.
Finder _findSemanticsWithLabel(String label) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == label,
);

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

/// Runs a `HomeScreen` widget-test [body] inside the standard
/// ProviderScope + MaterialApp.router shell at the requested surface
/// size.  Drives the viewport via both `tester.view.physicalSize` +
/// `devicePixelRatio = 1.0` AND `tester.binding.setSurfaceSize(...)` so
/// the `MediaQuery.of(context).size` reads inside `HomeScreen.build`
/// reliably see the requested logical size and pick the matching layout
/// branch (narrow < 600, wide 600–899, desktop ≥ 900).  Setting only
/// `setSurfaceSize` left the first frame rendering at the default
/// 800×600 logical viewport on this Flutter version, which caused
/// narrow-viewport tests to briefly render the wide layout and assert
/// against the wrong tree — hence we also pin `view.physicalSize`.
Future<void> _runHome(
  WidgetTester tester, {
  required Size size,
  required Future<void> Function() body,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  await tester.binding.setSurfaceSize(size);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.binding.setSurfaceSize(null);
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: _homeOverrides(),
      child: MaterialApp.router(
        theme: EchoTheme.darkTheme,
        darkTheme: EchoTheme.darkTheme,
        themeMode: ThemeMode.dark,
        routerConfig: _router(),
      ),
    ),
  );
  // First frame + drain the post-frame `_initData()` microtasks.  We
  // avoid pumpAndSettle: some upstream providers (voice, websocket
  // reconnect pulse) can keep the frame loop dirty forever in test mode.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  await body();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      // Avoid the first-login server-notice dialog blocking the empty-state
      // assertions in the wide/desktop tests.  The lifecycle part awaits
      // `_showServerNoticeIfNeeded` which reads this preference.
      'seen_server_notice': true,
    });
  });

  // -------------------------------------------------------------------------
  // Smoke — kept from the pre-split version.  Confirms the build path
  // mounts at the default test viewport without throwing.
  // -------------------------------------------------------------------------

  testWidgets('HomeScreen build path mounts without throwing', (tester) async {
    await _runHome(
      tester,
      size: const Size(1280, 800),
      body: () async {
        expect(find.byType(HomeScreen), findsOneWidget);
      },
    );
  });

  // -------------------------------------------------------------------------
  // narrow_layout part (< 600 px)
  // -------------------------------------------------------------------------

  group('narrow_layout (< 600px)', () {
    testWidgets('renders the mobile bottom tab bar with four tabs', (
      tester,
    ) async {
      await _runHome(
        tester,
        size: const Size(400, 800),
        body: () async {
          expect(_findSemanticsWithLabel('Chats tab'), findsOneWidget);
          expect(_findSemanticsWithLabel('Discover tab'), findsOneWidget);
          expect(_findSemanticsWithLabel('Contacts tab'), findsOneWidget);
          expect(_findSemanticsWithLabel('Settings tab'), findsOneWidget);
        },
      );
    });

    testWidgets('renders the four tab text labels', (tester) async {
      // "Chats" appears twice: once as the 28pt conversation-panel header
      // and once as the 10pt mobile-tab label.  Other tab labels (Discover/
      // Contacts/Settings) only appear as the tab label, so they're exactly
      // one each.  We use `findsAtLeastNWidgets(1)` for "Chats" to avoid
      // coupling to the header copy.
      await _runHome(
        tester,
        size: const Size(400, 800),
        body: () async {
          expect(find.text('Chats'), findsAtLeastNWidgets(1));
          expect(find.text('Discover'), findsAtLeastNWidgets(1));
          expect(find.text('Contacts'), findsAtLeastNWidgets(1));
          expect(find.text('Settings'), findsAtLeastNWidgets(1));
        },
      );
    });

    testWidgets('does NOT render the desktop AppTitleBar', (tester) async {
      // narrow_layout returns a plain Scaffold; only wide and desktop wrap
      // their body in an AppTitleBar.  Asserting the absence guards against
      // accidental cross-pollination if a refactor moves AppTitleBar up.
      await _runHome(
        tester,
        size: const Size(400, 800),
        body: () async {
          expect(find.byType(AppTitleBar), findsNothing);
        },
      );
    });

    testWidgets('Chats tab is initially selected (mobileTabIndex == 0)', (
      tester,
    ) async {
      await _runHome(
        tester,
        size: const Size(400, 800),
        body: () async {
          // The active tab has `Semantics(selected: true)` because
          // `_buildMobileTabItem` reads `isActive = index == _mobileTabIndex`
          // and feeds it through.  We inspect the Semantics widget
          // properties directly rather than the rendered semantic node
          // (which would require `tester.ensureSemantics()`) — same source
          // of truth, fewer test-mode side effects.
          final chats = tester.widget<Semantics>(
            _findSemanticsWithLabel('Chats tab'),
          );
          expect(chats.properties.selected, isTrue);

          final discover = tester.widget<Semantics>(
            _findSemanticsWithLabel('Discover tab'),
          );
          expect(discover.properties.selected, isFalse);
        },
      );
    });
  });

  // -------------------------------------------------------------------------
  // wide_layout part (600–899 px)
  // -------------------------------------------------------------------------

  group('wide_layout (600-899px)', () {
    testWidgets('renders AppTitleBar at the top of the layout', (tester) async {
      await _runHome(
        tester,
        size: const Size(800, 700),
        body: () async {
          // _buildWideLayout always wraps its body in a Column whose first
          // child is AppTitleBar.  Desktop also does, narrow does not.
          expect(find.byType(AppTitleBar), findsOneWidget);
        },
      );
    });

    testWidgets('shows the empty-state message when no conversation selected', (
      tester,
    ) async {
      await _runHome(
        tester,
        size: const Size(800, 700),
        body: () async {
          // _buildEmptyState (listeners.dart) is the right panel when no
          // conversation is selected.  Its copy is verbatim.
          expect(find.text('No conversation selected'), findsOneWidget);
          expect(
            find.text(
              'Choose a conversation from the sidebar or start a new chat.',
            ),
            findsOneWidget,
          );
        },
      );
    });

    testWidgets('does NOT render the mobile bottom tab bar', (tester) async {
      await _runHome(
        tester,
        size: const Size(800, 700),
        body: () async {
          // wide_layout has no bottom navigation; the four "<x> tab"
          // semantic nodes only exist in narrow_layout.
          expect(_findSemanticsWithLabel('Chats tab'), findsNothing);
          expect(_findSemanticsWithLabel('Settings tab'), findsNothing);
        },
      );
    });

    testWidgets('does NOT render the desktop resize handle', (tester) async {
      // The draggable sidebar resize handle only exists in desktop_layout
      // (`_buildResizeHandle`).  wide_layout uses a fixed 300 px sidebar.
      await _runHome(
        tester,
        size: const Size(800, 700),
        body: () async {
          expect(_findSemanticsWithLabel('Resize sidebar'), findsNothing);
        },
      );
    });
  });

  // -------------------------------------------------------------------------
  // desktop_layout part (>= 900 px)
  // -------------------------------------------------------------------------

  group('desktop_layout (>= 900px)', () {
    testWidgets('renders AppTitleBar at the top of the layout', (tester) async {
      await _runHome(
        tester,
        size: const Size(1280, 800),
        body: () async {
          expect(find.byType(AppTitleBar), findsOneWidget);
        },
      );
    });

    testWidgets('renders the draggable sidebar resize handle', (tester) async {
      // _buildResizeHandle uses `Semantics(label: 'Resize sidebar', ...)`
      // — the most reliable hook because the handle is otherwise just a
      // 12-px transparent GestureDetector and hard to find by type.
      await _runHome(
        tester,
        size: const Size(1280, 800),
        body: () async {
          expect(_findSemanticsWithLabel('Resize sidebar'), findsOneWidget);
        },
      );
    });

    testWidgets('shows the empty-state when no conversation selected', (
      tester,
    ) async {
      await _runHome(
        tester,
        size: const Size(1280, 800),
        body: () async {
          expect(find.text('No conversation selected'), findsOneWidget);
          // The empty state also surfaces two action buttons.  Asserting
          // them pins the empty-state composition since the buttons live
          // in _buildEmptyState (listeners.dart) alongside the headline.
          expect(find.text('Add contact'), findsOneWidget);
          expect(find.text('Browse groups'), findsOneWidget);
        },
      );
    });

    testWidgets('does NOT render the mobile bottom tab bar', (tester) async {
      await _runHome(
        tester,
        size: const Size(1280, 800),
        body: () async {
          expect(_findSemanticsWithLabel('Chats tab'), findsNothing);
          expect(_findSemanticsWithLabel('Discover tab'), findsNothing);
        },
      );
    });
  });

  // -------------------------------------------------------------------------
  // Cross-layout: the size-driven branch picker in HomeScreen.build().
  // These exist mostly to lock in the breakpoints — changing the
  // narrow/desktop thresholds (currently 600 / 900) will break them and
  // force a conscious decision about layout regressions.
  // -------------------------------------------------------------------------

  group('layout breakpoint switching', () {
    testWidgets('500 px viewport selects the narrow layout', (tester) async {
      await _runHome(
        tester,
        size: const Size(500, 800),
        body: () async {
          // Narrow signature: mobile tabs present, AppTitleBar absent.
          expect(_findSemanticsWithLabel('Chats tab'), findsOneWidget);
          expect(find.byType(AppTitleBar), findsNothing);
        },
      );
    });

    testWidgets('750 px viewport selects the wide (tablet) layout', (
      tester,
    ) async {
      await _runHome(
        tester,
        size: const Size(750, 700),
        body: () async {
          // Wide signature: AppTitleBar present, no resize handle, no
          // mobile tabs.
          expect(find.byType(AppTitleBar), findsOneWidget);
          expect(_findSemanticsWithLabel('Resize sidebar'), findsNothing);
          expect(_findSemanticsWithLabel('Chats tab'), findsNothing);
        },
      );
    });

    testWidgets('1280 px viewport selects the desktop layout', (tester) async {
      await _runHome(
        tester,
        size: const Size(1280, 800),
        body: () async {
          // Desktop signature: AppTitleBar + resize handle, no mobile tabs.
          expect(find.byType(AppTitleBar), findsOneWidget);
          expect(_findSemanticsWithLabel('Resize sidebar'), findsOneWidget);
          expect(_findSemanticsWithLabel('Chats tab'), findsNothing);
        },
      );
    });
  });
}
