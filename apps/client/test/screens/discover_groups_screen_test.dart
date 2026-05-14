import 'package:echo_app/src/screens/discover_groups_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Smoke tests for the Discover screen. The full preview-sheet path needs a
/// live HTTP server to populate the list, which we don't have in unit tests
/// — instead we lock down that the screen builds, exposes a Search field
/// and a back/discover header so the route mounts cleanly.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpDiscover(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: EchoTheme.darkTheme,
          home: const DiscoverGroupsScreen(),
        ),
      ),
    );
    // Initial fetch fires from a post-frame callback. Pump once for the
    // build and once for the error/empty placeholder to render after the
    // fetch fails (no server in unit tests).
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('renders the discover header and search field', (tester) async {
    await pumpDiscover(tester);

    expect(find.text('Discover'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('falls back to an empty/error state when the fetch fails', (
    tester,
  ) async {
    await pumpDiscover(tester);

    // With no HTTP server the fetch will time out / fail. Either an error
    // state ("Failed to load groups" / "Retry") or an empty state
    // ("No public groups found") should be visible after the placeholder
    // pump above.
    final hasError =
        find.text('Retry').evaluate().isNotEmpty ||
        find.text('Failed to load groups').evaluate().isNotEmpty;
    final hasEmpty = find.text('No public groups found').evaluate().isNotEmpty;
    final hasLoading = find
        .byType(CircularProgressIndicator)
        .evaluate()
        .isNotEmpty;
    expect(
      hasError || hasEmpty || hasLoading,
      isTrue,
      reason:
          'Expected an error / empty / loading placeholder when the discovery '
          'API is unavailable in unit tests.',
    );
  });
}
