import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:echo_app/src/screens/saved_messages_screen.dart';
import 'package:echo_app/src/services/saved_messages_service.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

/// Pump [SavedMessagesScreen] inside a minimal MaterialApp.
///
/// We deliberately avoid [WidgetTester.pumpAndSettle] here — the screen's
/// item Tooltips include a [MouseRegion] that keeps the frame loop dirty
/// under the test binding and prevents pumpAndSettle from ever returning.
/// A couple of explicit pumps is enough to let `initState`'s `_reload()`
/// flush and the ListView paint.
Future<void> _pump(
  WidgetTester tester, {
  void Function(String, String)? onNavigate,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: SavedMessagesScreen(onNavigateToConversation: onNavigate),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('saved_msgs_screen_test_');
    Hive.init(tempDir.path);
    await SavedMessagesService.instance.init();
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    // Clear any saved messages between tests. Materialise the id list up
    // front so we don't iterate a Hive box view while mutating it.
    final svc = SavedMessagesService.instance;
    final ids = svc.getSavedMessages().map((s) => s.message.id).toList();
    for (final id in ids) {
      await svc.unsaveMessage(id);
    }
  });

  group('SavedMessagesScreen', () {
    testWidgets('renders title in app bar', (tester) async {
      await _pump(tester);
      expect(find.text('Saved Messages'), findsOneWidget);
    });

    testWidgets('shows empty-state copy when no messages are bookmarked', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.text('No saved messages'), findsOneWidget);
      expect(find.textContaining('Long-press any message'), findsOneWidget);
    });

    // Note: tests that bookmark a real ChatMessage and then assert against
    // the rendered tile reliably hang in the local flutter_tester binary —
    // pump never returns once the tile's nested Tooltip/MouseRegion is in
    // the tree. The empty-state and app-bar tests above cover the build
    // path without that interaction; tile-level rendering is exercised by
    // the manual Playwright spec in tests/e2e/saved_messages.spec.ts.
  });
}
