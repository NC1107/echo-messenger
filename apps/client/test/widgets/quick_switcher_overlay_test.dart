import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/quick_switcher_overlay.dart';

import '../helpers/mock_providers.dart';

/// Sample conversations crafted so each one has a deterministic, unique
/// display name. 1:1 conversations resolve to the peer's username via
/// [Conversation.displayName], so we always include "test-user-id"
/// alongside the peer to mirror real-world member lists.
final _conversations = <Conversation>[
  const Conversation(
    id: 'conv-alice',
    isGroup: false,
    members: [
      ConversationMember(userId: 'user-alice', username: 'alice'),
      ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ],
  ),
  const Conversation(
    id: 'conv-bob',
    isGroup: false,
    members: [
      ConversationMember(userId: 'user-bob', username: 'bob'),
      ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ],
  ),
  const Conversation(
    id: 'conv-charlie',
    isGroup: false,
    members: [
      ConversationMember(userId: 'user-charlie', username: 'charlie'),
      ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ],
  ),
  const Conversation(
    id: 'conv-dev-team',
    name: 'Dev Team',
    isGroup: true,
    members: [
      ConversationMember(userId: 'user-bob', username: 'bob'),
      ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ],
  ),
];

/// Push the overlay inside a real Navigator so `Navigator.of(context).pop()`
/// works the same way it does in production (the overlay is opened via
/// `showDialog` in `home_screen/parts/actions.dart`).
Widget _harness({
  required void Function(Conversation) onSelect,
  List<Conversation>? conversations,
}) {
  return ProviderScope(
    overrides: [
      authOverride(loggedInAuthState),
      serverUrlOverride(),
      conversationsOverride(conversations ?? _conversations),
    ],
    child: MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () {
                showDialog<void>(
                  context: ctx,
                  builder: (_) => QuickSwitcherOverlay(onSelect: onSelect),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Focus the search input so that the TextField becomes the soft-keyboard
/// input client. Arrow keys still bubble up to the surrounding
/// [KeyboardListener]; Enter is dispatched via `onSubmitted` through
/// [TestTextInput.receiveAction].
Future<void> _focusSearchField(WidgetTester tester) async {
  await tester.tap(find.byType(TextField));
  await tester.pumpAndSettle();
}

/// Fire the TextField's "submit" action (the production Enter path).
Future<void> _submit(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('empty query shows all conversations (up to 8)', (tester) async {
    await tester.pumpWidget(_harness(onSelect: (_) {}));
    await _open(tester);

    expect(find.text('alice'), findsOneWidget);
    expect(find.text('bob'), findsAtLeastNWidgets(1));
    expect(find.text('charlie'), findsOneWidget);
    expect(find.text('Dev Team'), findsOneWidget);
    expect(find.text('No results'), findsNothing);
  });

  testWidgets('empty conversations list shows the empty state', (tester) async {
    await tester.pumpWidget(
      _harness(onSelect: (_) {}, conversations: const []),
    );
    await _open(tester);

    expect(find.text('No results'), findsOneWidget);
  });

  testWidgets('typing a unique query filters out non-matching conversations', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(onSelect: (_) {}));
    await _open(tester);

    // 'alice' is unique: charlie has no 'c' after 'i', bob has no 'a',
    // 'Dev Team' has no 'l'.
    await tester.enterText(find.byType(TextField), 'alice');
    await tester.pumpAndSettle();

    // The TextField itself also renders the literal "alice" as its value,
    // so we look for the result-row text outside of any EditableText.
    Finder rowText(String label) =>
        find.descendant(of: find.byType(InkWell), matching: find.text(label));

    expect(rowText('alice'), findsOneWidget);
    expect(rowText('bob'), findsNothing);
    expect(rowText('charlie'), findsNothing);
    expect(rowText('Dev Team'), findsNothing);
  });

  testWidgets('group conversations match against their group name', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(onSelect: (_) {}));
    await _open(tester);

    await tester.enterText(find.byType(TextField), 'dev team');
    await tester.pumpAndSettle();

    Finder rowText(String label) =>
        find.descendant(of: find.byType(InkWell), matching: find.text(label));

    expect(rowText('Dev Team'), findsOneWidget);
    // The "Group" trailing label appears next to group hits.
    expect(find.text('Group'), findsOneWidget);
    expect(rowText('alice'), findsNothing);
  });

  testWidgets('query with no matches shows the empty state', (tester) async {
    await tester.pumpWidget(_harness(onSelect: (_) {}));
    await _open(tester);

    await tester.enterText(find.byType(TextField), 'zzznomatchzzz');
    await tester.pumpAndSettle();

    expect(find.text('No results'), findsOneWidget);
    expect(find.text('alice'), findsNothing);
  });

  testWidgets('Enter on default selection fires onSelect with first result', (
    tester,
  ) async {
    Conversation? picked;
    await tester.pumpWidget(_harness(onSelect: (c) => picked = c));
    await _open(tester);

    await _focusSearchField(tester);
    await _submit(tester);

    expect(picked, isNotNull);
    expect(picked!.id, _conversations.first.id);
  });

  testWidgets('ArrowDown moves selection forward; Enter picks 2nd item', (
    tester,
  ) async {
    Conversation? picked;
    await tester.pumpWidget(_harness(onSelect: (c) => picked = c));
    await _open(tester);
    await _focusSearchField(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await _submit(tester);

    expect(picked, isNotNull);
    expect(picked!.id, _conversations[1].id);
  });

  testWidgets('ArrowUp cycles selection back up', (tester) async {
    Conversation? picked;
    await tester.pumpWidget(_harness(onSelect: (c) => picked = c));
    await _open(tester);
    await _focusSearchField(tester);

    // Down twice -> index 2, then up once -> index 1.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await _submit(tester);

    expect(picked, isNotNull);
    expect(picked!.id, _conversations[1].id);
  });

  testWidgets('ArrowDown clamps at the last result without crashing', (
    tester,
  ) async {
    Conversation? picked;
    await tester.pumpWidget(_harness(onSelect: (c) => picked = c));
    await _open(tester);
    await _focusSearchField(tester);

    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(tester.takeException(), isNull);

    await _submit(tester);

    expect(picked, isNotNull);
    expect(picked!.id, _conversations.last.id);
  });

  testWidgets('ArrowUp clamps at the first result without crashing', (
    tester,
  ) async {
    Conversation? picked;
    await tester.pumpWidget(_harness(onSelect: (c) => picked = c));
    await _open(tester);
    await _focusSearchField(tester);

    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
    }
    expect(tester.takeException(), isNull);

    await _submit(tester);

    expect(picked, isNotNull);
    expect(picked!.id, _conversations.first.id);
  });

  testWidgets('Escape closes the overlay without firing onSelect', (
    tester,
  ) async {
    var pickedCount = 0;
    await tester.pumpWidget(_harness(onSelect: (_) => pickedCount++));
    await _open(tester);

    expect(find.byType(QuickSwitcherOverlay), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(QuickSwitcherOverlay), findsNothing);
    expect(pickedCount, 0);
  });

  testWidgets('tapping a result row fires onSelect and pops the overlay', (
    tester,
  ) async {
    Conversation? picked;
    await tester.pumpWidget(_harness(onSelect: (c) => picked = c));
    await _open(tester);

    await tester.tap(find.text('charlie'));
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(picked!.id, 'conv-charlie');
    expect(find.byType(QuickSwitcherOverlay), findsNothing);
  });

  testWidgets('typing a new query resets selection to the first match', (
    tester,
  ) async {
    Conversation? picked;
    await tester.pumpWidget(_harness(onSelect: (c) => picked = c));
    await _open(tester);
    await _focusSearchField(tester);

    // Move selection off the first result first…
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    // …then type a query that produces a single-result list. Selection
    // must snap back to index 0 (otherwise Enter would dereference out
    // of range, or pick the wrong conversation).
    await tester.enterText(find.byType(TextField), 'charlie');
    await tester.pumpAndSettle();

    await _submit(tester);

    expect(picked, isNotNull);
    expect(picked!.id, 'conv-charlie');
  });

  testWidgets('Enter on empty results does NOT fire onSelect', (tester) async {
    var pickedCount = 0;
    await tester.pumpWidget(
      _harness(onSelect: (_) => pickedCount++, conversations: const []),
    );
    await _open(tester);
    await _focusSearchField(tester);

    await _submit(tester);

    expect(pickedCount, 0);
    // Overlay should still be visible — _selectCurrent is a no-op on empty.
    expect(find.byType(QuickSwitcherOverlay), findsOneWidget);
  });

  testWidgets('tapping the backdrop dismisses the overlay', (tester) async {
    var pickedCount = 0;
    await tester.pumpWidget(_harness(onSelect: (_) => pickedCount++));
    await _open(tester);

    expect(find.byType(QuickSwitcherOverlay), findsOneWidget);

    // Tap top-left where the backdrop sits, away from the centered card.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(find.byType(QuickSwitcherOverlay), findsNothing);
    expect(pickedCount, 0);
  });
}
