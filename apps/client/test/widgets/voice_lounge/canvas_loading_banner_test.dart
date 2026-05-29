import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/canvas_models.dart'
    show CanvasAttachState, CanvasState;
import 'package:echo_app/src/providers/canvas_provider.dart';
import 'package:echo_app/src/widgets/voice_lounge/canvas_loading_banner.dart';

// ---------------------------------------------------------------------------
// Minimal override: expose the CanvasController notifier with a preset state
// so widget tests drive just the banner without needing a full Flutter app
// or a live HTTP stack.
// ---------------------------------------------------------------------------

class _FakeCanvasNotifier extends CanvasController {
  _FakeCanvasNotifier(CanvasState preset) : _preset = preset;

  final CanvasState _preset;

  @override
  CanvasState build() => _preset;

  @override
  Future<void> attach(String conversationId, String channelId) async {}

  @override
  Future<void> retryAttach() async {
    retryCallCount++;
  }

  int retryCallCount = 0;
}

ProviderScope _wrapBanner({
  required CanvasState canvasState,
  _FakeCanvasNotifier? notifier,
}) {
  final fakeNotifier = notifier ?? _FakeCanvasNotifier(canvasState);
  return ProviderScope(
    overrides: [canvasControllerProvider.overrideWith(() => fakeNotifier)],
    child: const MaterialApp(home: Scaffold(body: CanvasLoadingBanner())),
  );
}

void main() {
  group('CanvasLoadingBanner', () {
    testWidgets('renders nothing when attachState is idle', (tester) async {
      await tester.pumpWidget(
        _wrapBanner(
          canvasState: const CanvasState(attachState: CanvasAttachState.idle),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Catching up…'), findsNothing);
      expect(find.textContaining("Couldn't load"), findsNothing);
    });

    testWidgets('renders nothing when attachState is loaded', (tester) async {
      await tester.pumpWidget(
        _wrapBanner(
          canvasState: const CanvasState(attachState: CanvasAttachState.loaded),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Catching up…'), findsNothing);
    });

    testWidgets('shows spinner and "Catching up…" when loading', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrapBanner(
          canvasState: CanvasState(
            attachState: CanvasAttachState.loading,
            attachStartedAt: DateTime.now(),
          ),
        ),
      );
      await tester.pump(); // let build run
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Catching up…'), findsOneWidget);
      expect(find.textContaining('Slow connection'), findsNothing);
    });

    testWidgets('text changes after 8 s to slow-connection message', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrapBanner(
          canvasState: CanvasState(
            attachState: CanvasAttachState.loading,
            attachStartedAt: DateTime.now(),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Catching up…'), findsOneWidget);

      await tester.pump(const Duration(seconds: 8));
      expect(find.textContaining('Slow connection'), findsOneWidget);
      expect(find.text('Catching up…'), findsNothing);
    });

    testWidgets('shows error message when attachState is failed', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrapBanner(
          canvasState: const CanvasState(attachState: CanvasAttachState.failed),
        ),
      );
      await tester.pump();
      expect(find.textContaining("Couldn't load canvas"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('tapping retry calls retryAttach', (tester) async {
      final notifier = _FakeCanvasNotifier(
        const CanvasState(attachState: CanvasAttachState.failed),
      );
      await tester.pumpWidget(
        _wrapBanner(canvasState: notifier.debugState, notifier: notifier),
      );
      await tester.pump();
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(notifier.retryCallCount, 1);
    });
  });
}

extension on _FakeCanvasNotifier {
  CanvasState get debugState => _preset;
}
