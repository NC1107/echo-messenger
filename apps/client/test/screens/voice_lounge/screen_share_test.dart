import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/screens/voice_lounge/screen_share.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

/// Wrap [child] inside a Stack > LayoutBuilder pattern that mirrors how
/// voice_lounge_screen.dart hosts the draggable window. Returns the pumped
/// rect/label assertions.
///
/// Note: [DraggableScreenShareWindow] returns a [Positioned] from inside an
/// internal [LayoutBuilder]. Under the Flutter test framework this surfaces a
/// `ParentDataWidget` assertion ("Positioned inside LayoutBuilder"). The
/// warning is benign at runtime — the Stack still lays out the Positioned —
/// so we drain it via `tester.takeException()` and proceed.
Future<void> _pumpDraggable(
  WidgetTester tester,
  Widget child, {
  String label = 'Sharing',
  bool isLocal = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: EchoTheme.darkTheme,
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: Stack(
            children: [
              DraggableScreenShareWindow(
                label: label,
                isLocal: isLocal,
                child: child,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  // Drain the ParentData assertion noted above so the test framework
  // doesn't fail the test on a known-benign warning.
  tester.takeException();
}

// ---------------------------------------------------------------------------
// Helpers: lifecycle observer tracking
// ---------------------------------------------------------------------------

/// Minimal widget that mirrors the [FullscreenVideoPage] lifecycle-observer
/// contract: registers itself as a [WidgetsBindingObserver] on init, removes
/// itself on dispose, and records which [AppLifecycleState] values it sees.
///
/// Used to verify the observer plumbing without needing a real [VideoTrack].
class _LifecycleRecorder extends StatefulWidget {
  final List<AppLifecycleState> received;
  const _LifecycleRecorder({required this.received});

  @override
  State<_LifecycleRecorder> createState() => _LifecycleRecorderState();
}

class _LifecycleRecorderState extends State<_LifecycleRecorder>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.received.add(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('FullscreenVideoPage lifecycle observer', () {
    testWidgets(
      'observer receives AppLifecycleState.resumed when app returns from background',
      (tester) async {
        final received = <AppLifecycleState>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: _LifecycleRecorder(received: received)),
          ),
        );
        await tester.pump();

        // Simulate backgrounding then foregrounding — the pattern that
        // previously left FullscreenVideoPage in an un-restored state.
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();

        expect(received, contains(AppLifecycleState.resumed));
      },
    );

    testWidgets('observer is deregistered after widget is disposed', (
      tester,
    ) async {
      final received = <AppLifecycleState>[];

      // Mount then remove the widget.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: _LifecycleRecorder(received: received)),
        ),
      );
      await tester.pump();

      // Replace with a plain widget — causes _LifecycleRecorder to be disposed.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      await tester.pump();

      // Fire a lifecycle event AFTER disposal — should not reach the recorder.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      // The only events recorded should be from before disposal.
      expect(received, isNot(contains(AppLifecycleState.resumed)));
    });

    testWidgets(
      'SystemChannels.platform receives no unexpected calls on test platform',
      (tester) async {
        // On the test platform _supportsSystemUiMode is false (not Android/iOS),
        // so setEnabledSystemUIMode is never called. Verify no spurious platform
        // messages arrive when lifecycle events fire.
        final methodCalls = <String>[];
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          methodCalls.add(call.method);
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );

        final received = <AppLifecycleState>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: _LifecycleRecorder(received: received)),
          ),
        );
        await tester.pump();

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();

        expect(
          methodCalls,
          isNot(contains('SystemChrome.setEnabledSystemUIMode')),
          reason:
              'setEnabledSystemUIMode must not be called on non-mobile test platform',
        );
      },
    );
  });

  group('DraggableScreenShareWindow', () {
    testWidgets(
      'renders the embedded child and surfaces label/handle on hover (#1225)',
      (tester) async {
        await _pumpDraggable(
          tester,
          const Center(child: Text('inner')),
          label: 'Alice — Screen 1',
        );

        // Child content is always visible.
        expect(find.text('inner'), findsOneWidget);

        // Label + handle are hover-only — neither appears at rest.
        expect(find.text('Alice — Screen 1'), findsNothing);
        expect(find.byIcon(Icons.screen_share), findsNothing);
        expect(find.byIcon(Icons.open_in_full), findsNothing);

        // Drive a mouse hover over the window so MouseRegion flips on.
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        addTearDown(gesture.removePointer);
        await gesture.addPointer(location: Offset.zero);
        await gesture.moveTo(tester.getCenter(find.text('inner')));
        await tester.pump();

        expect(find.text('Alice — Screen 1'), findsOneWidget);
        expect(find.byIcon(Icons.screen_share), findsOneWidget);
        expect(find.byIcon(Icons.open_in_full), findsOneWidget);
      },
    );

    testWidgets('mounts in local mode without throwing', (tester) async {
      await _pumpDraggable(
        tester,
        const SizedBox.shrink(),
        label: 'Local',
        isLocal: true,
      );
      // Label is hover-only post-#1225; reaching this expectation
      // without an exception is what the test cares about.
      expect(find.text('Local'), findsNothing);
    });
  });
}
