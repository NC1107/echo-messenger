import 'package:echo_app/src/models/contact.dart';
import 'package:echo_app/src/providers/contacts_provider.dart';
import 'package:echo_app/src/screens/new_message_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mock_providers.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _alice = Contact(
  id: 'c-alice',
  userId: 'u-alice',
  username: 'alice',
  displayName: 'Alice A',
  status: 'accepted',
);

const _bob = Contact(
  id: 'c-bob',
  userId: 'u-bob',
  username: 'bob',
  displayName: 'Bob B',
  status: 'accepted',
);

/// A [_FakeContactsWithData] override that pre-loads a contact list so tests
/// never need a live server. Contacts are visible immediately after `build()`.
class _FakeContactsWithData extends Contacts {
  _FakeContactsWithData(this._contacts);
  final List<Contact> _contacts;

  @override
  ContactsState build() => ContactsState(contacts: _contacts);

  @override
  Future<void> loadContacts() async {}

  @override
  Future<void> loadPending({bool force = false}) async {}
}

Override contactsWithData(List<Contact> contacts) {
  return contactsProvider.overrideWith(() => _FakeContactsWithData(contacts));
}

Future<void> pumpScreen(
  WidgetTester tester, {
  List<Override> extra = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...standardOverrides(),
        contactsWithData([_alice, _bob]),
        ...extra,
      ],
      child: MaterialApp(
        theme: EchoTheme.darkTheme,
        darkTheme: EchoTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: const NewMessageScreen(),
      ),
    ),
  );
  // One frame for initState post-frame callback, one more for any async state.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('NewMessageScreen (search + tappable rows)', () {
    testWidgets('shows contacts and a New group entry, no chips', (
      tester,
    ) async {
      await pumpScreen(tester);

      expect(find.text('New chat'), findsOneWidget); // header
      expect(find.text('New group'), findsOneWidget); // pinned row
      expect(find.text('Alice A'), findsOneWidget);
      expect(find.text('Bob B'), findsOneWidget);
      // No chip ceremony / "Start chat" CTA in the new design.
      expect(find.textContaining('Start chat'), findsNothing);
    });

    testWidgets('typing filters the contact list', (tester) async {
      await pumpScreen(tester);

      await tester.enterText(find.byType(TextField).first, 'ali');
      await tester.pump();

      expect(find.text('Alice A'), findsOneWidget);
      expect(find.text('Bob B'), findsNothing);
      // The "New group" row only shows on the empty query.
      expect(find.text('New group'), findsNothing);
    });

    testWidgets('tapping New group enters group mode with checkboxes', (
      tester,
    ) async {
      await pumpScreen(tester);

      await tester.tap(find.text('New group'));
      await tester.pump();

      // Header title flips, a disabled Create-group CTA + checkboxes appear.
      expect(find.widgetWithText(FilledButton, 'Create group'), findsOneWidget);
      expect(find.byType(Checkbox), findsNWidgets(2)); // alice + bob

      final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Create group'),
      );
      expect(btn.onPressed, isNull); // nothing selected yet
    });

    testWidgets('selecting members enables + counts the Create group CTA', (
      tester,
    ) async {
      await pumpScreen(tester);
      await tester.tap(find.text('New group'));
      await tester.pump();

      await tester.tap(find.text('Alice A'));
      await tester.pump();
      expect(
        find.widgetWithText(FilledButton, 'Create group · 1'),
        findsOneWidget,
      );

      await tester.tap(find.text('Bob B'));
      await tester.pump();
      final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Create group · 2'),
      );
      expect(btn.onPressed, isNotNull); // enabled with 2 selected
    });
  });
}
