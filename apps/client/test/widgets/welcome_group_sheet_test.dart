import 'package:echo_app/src/providers/featured_group_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/welcome_group_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/mock_providers.dart';

void main() {
  const group = FeaturedGroup(
    id: 'g-1',
    title: 'Echo Public Group',
    description: 'Say hello to everyone on Echo.',
    iconUrl: null,
    memberCount: 4,
    isMember: false,
  );

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverUrlProvider.overrideWith(
            () => FakeServerUrlNotifier('http://localhost:8080'),
          ),
        ],
        child: MaterialApp(
          theme: EchoTheme.darkTheme,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showWelcomeGroupSheet(context, group),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders the group, description and actions', (tester) async {
    await pump(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Echo'), findsOneWidget);
    expect(find.text('Echo Public Group'), findsOneWidget);
    expect(find.text('4 members'), findsOneWidget);
    expect(find.text('Say hello to everyone on Echo.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Join group'), findsOneWidget);
    expect(find.text('Maybe later'), findsOneWidget);
  });

  testWidgets('"Maybe later" dismisses the sheet', (tester) async {
    await pump(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Echo Public Group'), findsOneWidget);

    await tester.tap(find.text('Maybe later'));
    await tester.pumpAndSettle();

    expect(find.text('Echo Public Group'), findsNothing);
  });
}
