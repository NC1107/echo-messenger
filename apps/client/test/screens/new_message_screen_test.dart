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
  group('NewMessageScreen chip flow', () {
    testWidgets('typing a name and pressing Enter materialises a chip', (
      tester,
    ) async {
      await pumpScreen(tester);

      // The "To:" label and search field should be visible.
      expect(find.text('To:'), findsOneWidget);
      expect(find.byType(TextField), findsAtLeastNWidgets(1));

      // Type "alice" into the search field.
      await tester.enterText(find.byType(TextField).first, 'alice');
      await tester.pump();

      // Submit (simulates pressing Enter / done action on the field).
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // Alice should now appear as a chip with "@Alice A" (displayName).
      expect(find.text('@Alice A'), findsOneWidget);

      // The "Start chat with @Alice A" CTA should be active.
      expect(find.text('Start chat with @Alice A'), findsOneWidget);
    });

    testWidgets(
      'adding a second chip switches CTA to "Create group" and shows group name field',
      (tester) async {
        await pumpScreen(tester);

        // Add alice chip.
        await tester.enterText(find.byType(TextField).first, 'alice');
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();

        expect(find.text('@Alice A'), findsOneWidget);

        // Add bob chip.
        await tester.enterText(find.byType(TextField).first, 'bob');
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();

        expect(find.text('@Bob B'), findsOneWidget);

        // "Create group" CTA should be visible.
        expect(find.text('Create group'), findsOneWidget);

        // The group name text field should have appeared.
        // There are now 2 TextFields: the chip-search field + the group name field.
        expect(find.byType(TextField), findsAtLeastNWidgets(2));
      },
    );

    testWidgets(
      'removing a chip via the × button reverts CTA to single-chip label',
      (tester) async {
        await pumpScreen(tester);

        // Add both chips.
        await tester.enterText(find.byType(TextField).first, 'alice');
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();

        await tester.enterText(find.byType(TextField).first, 'bob');
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();

        expect(find.text('Create group'), findsOneWidget);

        // Tap the × on the Bob chip (Semantics label "remove Bob B").
        final removeButton = find.bySemanticsLabel('remove Bob B');
        expect(removeButton, findsOneWidget);
        await tester.tap(removeButton);
        await tester.pump();

        // Back to 1 chip — CTA reverts.
        expect(find.text('Start chat with @Alice A'), findsOneWidget);
        expect(find.text('Create group'), findsNothing);
      },
    );

    testWidgets('with zero chips the Start chat button is disabled', (
      tester,
    ) async {
      await pumpScreen(tester);

      final btn = find.widgetWithText(FilledButton, 'Start chat');
      expect(btn, findsOneWidget);

      final filledBtn = tester.widget<FilledButton>(btn);
      expect(filledBtn.onPressed, isNull);
    });
  });
}
