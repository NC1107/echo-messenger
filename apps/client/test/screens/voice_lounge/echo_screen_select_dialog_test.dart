import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/screens/voice_lounge/echo_screen_select_dialog.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

/// The dialog leans on the `flutter_webrtc` `desktopCapturer` plugin to
/// enumerate screens / windows. In the test binary that plugin's platform
/// channel is unimplemented, so we stub it to return an empty list — the
/// dialog falls into its "no sources yet" loading state, which is exactly
/// the surface we can usefully assert without a real desktop capturer.
void _stubDesktopCapturer() {
  const channel = MethodChannel('FlutterWebRTC.Method');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getDesktopSources') {
          return {'sources': <Map<String, dynamic>>[]};
        }
        if (call.method == 'updateDesktopSources') return null;
        return null;
      });
}

void main() {
  setUp(_stubDesktopCapturer);

  group('showEchoScreenSelectDialog', () {
    testWidgets('renders header, tabs, and action buttons', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: EchoTheme.darkTheme,
          darkTheme: EchoTheme.darkTheme,
          themeMode: ThemeMode.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showEchoScreenSelectDialog(context),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      // Tabs animate in; allow a few frames without full settle (the
      // 3-second refresh timer in the dialog would otherwise spin forever).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Choose what to share'), findsOneWidget);
      expect(find.text('Entire Screen'), findsOneWidget);
      expect(find.text('Window'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
    });

    testWidgets('Share button starts disabled when no source is selected', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: EchoTheme.darkTheme,
          darkTheme: EchoTheme.darkTheme,
          themeMode: ThemeMode.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showEchoScreenSelectDialog(context),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final share = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Share'),
      );
      expect(share.onPressed, isNull);
    });

    // Regression guard for #1158. The dialog subscribes to three broadcast
    // streams from `flutter_webrtc`'s desktopCapturer and cancels them in
    // dispose() with `unawaited(sub.cancel())`. If the cancel future
    // rejects (e.g. PlatformException('No active stream to cancel') when
    // the native broadcast stream has already torn down), the rejection
    // must not escape to the uncaught-async zone. We verify dispose runs
    // cleanly and that `tester.takeException()` reports nothing.
    testWidgets('closing the dialog does not throw uncaught async errors', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: EchoTheme.darkTheme,
          darkTheme: EchoTheme.darkTheme,
          themeMode: ThemeMode.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showEchoScreenSelectDialog(context),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Give the unawaited cancel futures a chance to settle.
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
    });
  });
}
