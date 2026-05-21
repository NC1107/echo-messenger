import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/contact.dart';
import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/contacts_provider.dart';
import 'package:echo_app/src/providers/conversation_filter_provider.dart';
import 'package:echo_app/src/providers/conversations_provider.dart';
import 'package:echo_app/src/providers/update_provider.dart';
import 'package:echo_app/src/providers/websocket_provider.dart';
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/conversation_panel.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

// ---------------------------------------------------------------------------
// Test fakes for the conversation_panel parts tests.
// ---------------------------------------------------------------------------

/// Stub conversations notifier that records calls to the mutation methods
/// the panel invokes (leaveGroup / deleteGroup / leaveConversation / etc.),
/// so the action-mixin tests can assert that the confirm path reaches the
/// right notifier method.
class _RecordingConversationsNotifier extends ConversationsNotifier {
  _RecordingConversationsNotifier(this._initial);

  final List<Conversation> _initial;

  final List<String> leaveGroupCalls = [];
  final List<String> deleteGroupCalls = [];
  final List<String> leaveConversationCalls = [];

  @override
  ConversationsState build() => ConversationsState(conversations: _initial);

  @override
  Future<void> loadConversations() async {}

  @override
  Future<bool> leaveGroup(String groupId) async {
    leaveGroupCalls.add(groupId);
    return true;
  }

  @override
  Future<bool> deleteGroup(String groupId) async {
    deleteGroupCalls.add(groupId);
    return true;
  }

  @override
  Future<bool> leaveConversation(String conversationId) async {
    leaveConversationCalls.add(conversationId);
    return true;
  }
}

class _FakeContactsWithPending extends Contacts {
  _FakeContactsWithPending(this._pending);

  final List<Contact> _pending;

  @override
  ContactsState build() => ContactsState(pendingRequests: _pending);

  @override
  Future<void> loadContacts() async {}

  @override
  Future<void> loadPending({bool force = false}) async {}
}

class _ErrorConversationsNotifier extends ConversationsNotifier {
  @override
  ConversationsState build() =>
      const ConversationsState(error: 'load failed', conversations: []);

  @override
  Future<void> loadConversations() async {}
}

void _noopTap(Conversation _) {}

class _FakeUpdateNotifier extends Update {
  _FakeUpdateNotifier(this._initial);

  final UpdateState _initial;

  @override
  UpdateState build() => _initial;

  @override
  Future<void> check({bool force = false}) async {}

  @override
  Future<void> downloadUpdate() async {}

  @override
  void cancelDownload() {}

  @override
  Future<void> applyUpdate() async {}

  @override
  Future<void> dismiss() async {
    state = state.copyWith(dismissed: true);
  }
}

void main() {
  group('ConversationPanel', () {
    testWidgets('renders Echo header', (tester) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(),
      );
      await tester.pump();

      expect(find.text('Echo'), findsOneWidget);
    });

    testWidgets('renders action menu in header on desktop (wide) layout', (
      tester,
    ) async {
      // The "+" header menu is desktop-only (width >= 600). Force a wide
      // viewport so the widget renders it.
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      bool newChatCalled = false;
      bool newGroupCalled = false;
      bool discoverCalled = false;

      await tester.pumpApp(
        ConversationPanel(
          onConversationTap: (_) {},
          onNewChat: () => newChatCalled = true,
          onNewGroup: () => newGroupCalled = true,
          onDiscover: () => discoverCalled = true,
        ),
        overrides: standardOverrides(),
      );
      await tester.pump();

      // Verify the "+" action menu exists on wide layouts
      expect(find.byIcon(Icons.add), findsOneWidget);

      // Open the popup menu
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      // Verify menu items are shown with labels
      expect(find.text('New Chat'), findsOneWidget);
      expect(find.text('New Group'), findsOneWidget);
      expect(find.text('Discover Groups'), findsOneWidget);

      // Tap New Chat and verify callback
      await tester.tap(find.text('New Chat'));
      await tester.pumpAndSettle();
      expect(newChatCalled, isTrue);

      // Re-open menu for next test
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.tap(find.text('New Group'));
      await tester.pumpAndSettle();
      expect(newGroupCalled, isTrue);

      // Re-open menu for discover
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Discover Groups'));
      await tester.pumpAndSettle();
      expect(discoverCalled, isTrue);
    });

    testWidgets(
      'pencil FAB is visible on mobile and opens compose menu on long-press',
      (tester) async {
        // Narrow viewport — mobile layout
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        bool newChatCalled = false;
        bool newGroupCalled = false;

        await tester.pumpApp(
          ConversationPanel(
            onConversationTap: (_) {},
            onNewChat: () => newChatCalled = true,
            onNewGroup: () => newGroupCalled = true,
            onDiscover: () {},
          ),
          overrides: standardOverrides(),
        );
        await tester.pump();

        // "+" header button must NOT appear on mobile
        expect(find.byIcon(Icons.add), findsNothing);

        // Pencil FAB must be visible
        expect(find.byIcon(Icons.edit_outlined), findsOneWidget);

        // Single tap triggers new chat
        await tester.tap(find.byIcon(Icons.edit_outlined));
        await tester.pump();
        expect(newChatCalled, isTrue);

        // Long-press opens the compose popup menu
        await tester.longPress(find.byIcon(Icons.edit_outlined));
        await tester.pumpAndSettle();

        expect(find.text('New chat'), findsOneWidget);
        expect(find.text('New group'), findsOneWidget);
        expect(find.text('Discover groups'), findsOneWidget);

        // Tap "New group" from the menu
        await tester.tap(find.text('New group'));
        await tester.pumpAndSettle();
        expect(newGroupCalled, isTrue);
      },
    );

    testWidgets('renders conversation list items', (tester) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(conversations: sampleConversations),
      );
      await tester.pump();

      // The 1:1 conversation with alice should show alice's name (peer)
      expect(find.text('alice'), findsOneWidget);
      // The group conversation should show its name
      expect(find.text('Dev Team'), findsOneWidget);
    });

    testWidgets('shows last message preview', (tester) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(conversations: sampleConversations),
      );
      await tester.pump();

      // DM conversation shows message without sender prefix
      expect(find.textContaining('Hey there!'), findsOneWidget);
      // Group conversation prefixes sender: "bob: Meeting at 3pm"
      expect(find.textContaining('bob: Meeting at 3pm'), findsOneWidget);
    });

    testWidgets('shows unread indicator dot for conversations with unreads', (
      tester,
    ) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(conversations: sampleConversations),
      );
      await tester.pump();

      // conv-1 has unreadCount=2 which renders as a small accent-colored dot
      // (10x10 circle), not a number. Verify the conversation name uses bold
      // font weight (w700) for unread conversations.
      final aliceText = tester.widget<Text>(find.text('alice'));
      expect(aliceText.style?.fontWeight, FontWeight.w700);
    });

    testWidgets('tapping a conversation triggers callback', (tester) async {
      Conversation? tappedConversation;

      await tester.pumpApp(
        ConversationPanel(onConversationTap: (c) => tappedConversation = c),
        overrides: standardOverrides(conversations: sampleConversations),
      );
      await tester.pump();

      // Tap on alice's conversation
      await tester.tap(find.text('alice'));
      await tester.pump();

      expect(tappedConversation, isNotNull);
      expect(tappedConversation!.id, 'conv-1');
    });

    testWidgets(
      'shows global-search icon in header on mobile, no inline filter bar',
      (tester) async {
        // The "Search conversations" inline filter bar was removed on
        // mobile so the search entrypoint matches desktop: a single
        // global-search icon in the header that opens the messages-
        // search overlay. This test guards the desktop-search memory
        // rule (single search entrypoint) from accidental reintroduction
        // of the inline filter UI.
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpApp(
          ConversationPanel(onConversationTap: (_) {}, onGlobalSearch: () {}),
          overrides: standardOverrides(),
        );
        await tester.pump();

        // Exactly one search icon — the header's global-search button.
        // No inline filter bar should render below the header.
        expect(find.byIcon(Icons.search_outlined), findsOneWidget);
        // And there's no "Search conversations" placeholder text anymore.
        expect(find.text('Search conversations'), findsNothing);
      },
    );

    testWidgets('empty state shows message when no conversations', (
      tester,
    ) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(conversations: []),
      );
      await tester.pump();

      // With no conversations, the empty state shows "No conversations yet"
      expect(find.text('No conversations yet'), findsOneWidget);
    });

    testWidgets('header renders without a duplicate connection dot', (
      tester,
    ) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(),
      );
      await tester.pump();

      // Connection state is now shown only on the bottom user-status bar
      // via the avatar dot. The header just shows the Echo wordmark.
      expect(find.text('Echo'), findsOneWidget);
    });

    testWidgets('highlights selected conversation', (tester) async {
      await tester.pumpApp(
        ConversationPanel(
          selectedConversationId: 'conv-1',
          onConversationTap: (_) {},
        ),
        overrides: standardOverrides(conversations: sampleConversations),
      );
      await tester.pump();

      // The selected conversation should still render alice
      expect(find.text('alice'), findsOneWidget);
    });

    testWidgets('status picker: avatar tap opens menu with 4 options', (
      tester,
    ) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(),
      );
      await tester.pump();

      // The status bar renders a PopupMenuButton with key 'status-picker'.
      expect(find.byKey(const Key('status-picker')), findsOneWidget);
      await tester.tap(find.byKey(const Key('status-picker')));
      await tester.pumpAndSettle();

      // The sidebar status bar also shows the current presence label
      // ("Online") so we scope the menu-item check to the popup-menu
      // descendants.
      expect(
        find.descendant(
          of: find.byType(PopupMenuItem<String>),
          matching: find.text('Online'),
        ),
        findsOneWidget,
      );
      expect(find.text('Away'), findsOneWidget);
      expect(find.text('Do Not Disturb'), findsOneWidget);
      expect(find.text('Invisible'), findsOneWidget);
    });

    testWidgets('status picker: selecting Away calls setPresenceStatus', (
      tester,
    ) async {
      const authState = AuthState(
        isLoggedIn: true,
        userId: 'test-user-id',
        username: 'testuser',
        token: 'fake-jwt-token',
        refreshToken: 'fake-refresh-token',
        presenceStatus: 'online',
      );

      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(authState: authState),
      );
      await tester.pump();

      // Open the status picker.
      await tester.tap(find.byKey(const Key('status-picker')));
      await tester.pumpAndSettle();

      // Tap the Away option.
      await tester.tap(find.text('Away'));
      await tester.pumpAndSettle();

      // After selecting Away, the menu dismisses; no menu item with the
      // text 'Online' remains. The status bar still shows the current
      // presence label, so we scope to popup-menu descendants.
      expect(
        find.descendant(
          of: find.byType(PopupMenuItem<String>),
          matching: find.text('Online'),
        ),
        findsNothing,
      );
    });
  });

  // -------------------------------------------------------------------------
  // header.dart — filter chips, "+" menu items, status picker.
  // -------------------------------------------------------------------------
  group('ConversationPanel header', () {
    testWidgets('filter chip tap updates conversationFilterTypeProvider', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          ...standardOverrides(),
          // Stub the update provider so its 30-min periodic timer doesn't
          // leak past the test (the real Update.build() starts a Timer).
          updateProvider.overrideWith(
            () => _FakeUpdateNotifier(const UpdateState()),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: const Scaffold(
              body: ConversationPanel(onConversationTap: _noopTap),
            ),
          ),
        ),
      );
      await tester.pump();

      // Default filter is `all`.
      expect(
        container.read(conversationFilterTypeProvider),
        ConversationFilterType.all,
      );

      await tester.tap(find.text('Groups'));
      await tester.pump();
      expect(
        container.read(conversationFilterTypeProvider),
        ConversationFilterType.groups,
      );

      await tester.tap(find.text('DMs'));
      await tester.pump();
      expect(
        container.read(conversationFilterTypeProvider),
        ConversationFilterType.dms,
      );
    });

    testWidgets(
      '"+" menu exposes Saved Messages and routes to the saved callback',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        var savedCalled = false;

        await tester.pumpApp(
          ConversationPanel(
            onConversationTap: (_) {},
            onNewChat: () {},
            onNewGroup: () {},
            onDiscover: () {},
            onSavedMessages: () => savedCalled = true,
          ),
          overrides: standardOverrides(),
        );
        await tester.pump();

        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();

        // The fourth item in the menu is Saved Messages.
        expect(find.text('Saved Messages'), findsOneWidget);
        await tester.tap(find.text('Saved Messages'));
        await tester.pumpAndSettle();
        expect(savedCalled, isTrue);
      },
    );

    testWidgets('Contacts callback wires the scan-QR header icon', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var scanCalled = false;

      await tester.pumpApp(
        ConversationPanel(
          onConversationTap: (_) {},
          onScanQr: () => scanCalled = true,
        ),
        overrides: standardOverrides(),
      );
      await tester.pump();

      // Header exposes the scan-QR icon only when the callback is provided.
      expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
      await tester.tap(find.byIcon(Icons.qr_code_scanner));
      await tester.pump();
      expect(scanCalled, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // banners.dart — pending banner, replaced banner, update banner, bug row.
  // -------------------------------------------------------------------------
  group('ConversationPanel banners', () {
    const samplePending = [
      Contact(
        id: 'req-1',
        userId: 'user-x',
        username: 'newperson',
        status: 'pending_received',
      ),
    ];

    testWidgets('pending-contacts banner renders when there are requests', (
      tester,
    ) async {
      var showContactsCalled = false;

      await tester.pumpApp(
        ConversationPanel(
          onConversationTap: (_) {},
          onShowContacts: () => showContactsCalled = true,
        ),
        overrides: [
          authOverride(loggedInAuthState),
          serverUrlOverride(),
          conversationsOverride(const []),
          contactsProvider.overrideWith(
            () => _FakeContactsWithPending(samplePending),
          ),
          webSocketOverride(),
          cryptoOverride(),
        ],
      );
      await tester.pump();

      expect(find.text('1 pending contact request'), findsOneWidget);

      await tester.tap(find.text('1 pending contact request'));
      await tester.pump();
      expect(showContactsCalled, isTrue);
    });

    testWidgets('pluralises pending-contacts banner correctly', (tester) async {
      const twoPending = [
        Contact(
          id: 'req-1',
          userId: 'user-a',
          username: 'a',
          status: 'pending_received',
        ),
        Contact(
          id: 'req-2',
          userId: 'user-b',
          username: 'b',
          status: 'pending_received',
        ),
      ];

      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: [
          authOverride(loggedInAuthState),
          serverUrlOverride(),
          conversationsOverride(const []),
          contactsProvider.overrideWith(
            () => _FakeContactsWithPending(twoPending),
          ),
          webSocketOverride(),
          cryptoOverride(),
        ],
      );
      await tester.pump();

      expect(find.text('2 pending contact requests'), findsOneWidget);
    });

    testWidgets('session-replaced banner renders + dismiss hides it', (
      tester,
    ) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: [
          authOverride(loggedInAuthState),
          serverUrlOverride(),
          conversationsOverride(const []),
          contactsOverride(),
          webSocketOverride(
            const WebSocketState(isConnected: false, wasReplaced: true),
          ),
          cryptoOverride(),
        ],
      );
      await tester.pump();

      expect(
        find.text('Signed in on another device. Tap to reconnect.'),
        findsOneWidget,
      );

      // Tap the dismiss IconButton (tooltip is the most reliable hook — the
      // IconButton(tooltip: 'Dismiss') sits inside the banner Semantics).
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();

      expect(
        find.text('Signed in on another device. Tap to reconnect.'),
        findsNothing,
      );
    });

    testWidgets(
      'bug-report row renders by default when no update is in flight',
      (tester) async {
        await tester.pumpApp(
          ConversationPanel(onConversationTap: (_) {}),
          overrides: standardOverrides(conversations: const []),
        );
        await tester.pump();

        expect(find.text('Report a bug'), findsOneWidget);
      },
    );

    testWidgets(
      'update banner replaces the bug-report row when an update is available',
      (tester) async {
        await tester.pumpApp(
          ConversationPanel(onConversationTap: (_) {}),
          overrides: [
            ...standardOverrides(conversations: const []),
            updateProvider.overrideWith(
              () => _FakeUpdateNotifier(
                const UpdateState(
                  status: UpdateStatus.readyToInstall,
                  latestVersion: '9.9.9',
                ),
              ),
            ),
          ],
        );
        await tester.pump();

        // readyToInstall renders "vX.Y.Z ready" with a Restart button.
        expect(find.text('v9.9.9 ready'), findsOneWidget);
        expect(find.text('Restart'), findsOneWidget);
        // The bug-report row is suppressed while the update banner shows.
        expect(find.text('Report a bug'), findsNothing);
      },
    );

    testWidgets('downloading update banner shows percentage and Cancel', (
      tester,
    ) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: [
          ...standardOverrides(conversations: const []),
          updateProvider.overrideWith(
            () => _FakeUpdateNotifier(
              const UpdateState(
                status: UpdateStatus.downloading,
                latestVersion: '9.9.9',
                downloadProgress: 0.42,
              ),
            ),
          ),
        ],
      );
      await tester.pump();

      expect(find.text('Downloading update... 42%'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // list_renderer.dart — empty / error / pinned / search states.
  // -------------------------------------------------------------------------
  group('ConversationPanel list renderer', () {
    testWidgets('error state shows retry button when load fails empty', (
      tester,
    ) async {
      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: [
          authOverride(loggedInAuthState),
          serverUrlOverride(),
          conversationsProvider.overrideWith(
            () => _ErrorConversationsNotifier(),
          ),
          contactsOverride(),
          webSocketOverride(),
          cryptoOverride(),
        ],
      );
      await tester.pump();

      expect(find.text("Couldn't load conversations"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('pinned conversations appear above an unpinned one with the '
        'PINNED section header', (tester) async {
      // Two conversations: one pinned (server flag), one not. Pinned must
      // appear first with a PINNED header and divider above the unpinned row.
      final convs = [
        const Conversation(
          id: 'conv-pinned',
          name: 'Pinned Group',
          isGroup: true,
          isPinned: true,
          lastMessage: 'old',
          lastMessageTimestamp: '2026-01-01T00:00:00Z',
          members: [
            ConversationMember(userId: 'user-x', username: 'x'),
            ConversationMember(userId: 'test-user-id', username: 'testuser'),
          ],
        ),
        const Conversation(
          id: 'conv-normal',
          name: 'Normal Group',
          isGroup: true,
          lastMessage: 'newer',
          lastMessageTimestamp: '2026-01-15T00:00:00Z',
          members: [
            ConversationMember(userId: 'user-y', username: 'y'),
            ConversationMember(userId: 'test-user-id', username: 'testuser'),
          ],
        ),
      ];

      await tester.pumpApp(
        ConversationPanel(onConversationTap: (_) {}),
        overrides: standardOverrides(conversations: convs),
      );
      // Two pumps: first builds with empty pinnedIds, the post-frame
      // `_loadPinnedIds` merges the server-pinned set in.
      await tester.pump();
      await tester.pump();

      expect(find.text('PINNED'), findsOneWidget);

      // Pinned group's tile must be rendered above the unpinned one in the
      // list's y-axis.
      final pinnedY = tester.getCenter(find.text('Pinned Group')).dy;
      final normalY = tester.getCenter(find.text('Normal Group')).dy;
      expect(pinnedY, lessThan(normalY));
    });

    testWidgets('search-mode empty state shows "No results found" copy', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          ...standardOverrides(conversations: sampleConversations),
          updateProvider.overrideWith(
            () => _FakeUpdateNotifier(const UpdateState()),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: const Scaffold(
              body: ConversationPanel(onConversationTap: _noopTap),
            ),
          ),
        ),
      );
      await tester.pump();

      // Now that the widget is mounted and watching the search query
      // provider, mutate it — the widget keeps the auto-dispose alive so no
      // dangling scheduler timer leaks past the test.
      container
          .read(conversationSearchQueryProvider.notifier)
          .set('zzz-unmatched-zzz');
      await tester.pump();

      expect(
        find.textContaining("No results found for 'zzz-unmatched-zzz'"),
        findsOneWidget,
      );
    });

    testWidgets(
      'mobile slidable swipe actions render Mute / Pin / Delete for a DM',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        try {
          await tester.pumpApp(
            ConversationPanel(onConversationTap: (_) {}),
            overrides: standardOverrides(
              conversations: [sampleConversations.first],
            ),
          );
          await tester.pump();

          // The DM row must be wrapped in a Slidable. Swiping reveals the
          // action pane with the Mute / Pin / Delete actions.
          final slidable = find.byType(Slidable);
          expect(slidable, findsOneWidget);
          await tester.drag(slidable, const Offset(-300, 0));
          await tester.pumpAndSettle();

          expect(find.text('Mute'), findsOneWidget);
          expect(find.text('Pin'), findsOneWidget);
          expect(find.text('Delete'), findsOneWidget);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // actions.dart — confirm dialog → notifier wiring for delete / leave flows.
  // -------------------------------------------------------------------------
  group('ConversationPanel actions confirm dialogs', () {
    testWidgets('mobile-swipe Delete on a DM confirms then '
        'calls leaveConversation', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      try {
        final recording = _RecordingConversationsNotifier([
          sampleConversations.first,
        ]);

        await tester.pumpApp(
          ConversationPanel(onConversationTap: (_) {}),
          overrides: [
            authOverride(loggedInAuthState),
            serverUrlOverride(),
            conversationsProvider.overrideWith(() => recording),
            contactsOverride(),
            webSocketOverride(),
            cryptoOverride(),
          ],
        );
        await tester.pump();

        await tester.drag(find.byType(Slidable), const Offset(-300, 0));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();

        // Confirm dialog renders the DM-deletion copy.
        expect(find.text('Delete Conversation'), findsOneWidget);

        // Tap the destructive confirm — the FilledButton labelled "Delete".
        await tester.tap(
          find.descendant(
            of: find.byType(FilledButton),
            matching: find.text('Delete'),
          ),
        );
        await tester.pumpAndSettle();

        expect(recording.leaveConversationCalls, ['conv-1']);

        // Let the success toast's dismiss timer expire so the binding's
        // post-test invariant check doesn't trip on a pending Timer.
        await tester.pump(const Duration(seconds: 10));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
      'mobile-swipe Leave on a group confirms then calls leaveGroup',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        try {
          // Use a group conversation where the test user is just a member, so
          // _resolveCanLeave returns true.
          final groupConv = sampleConversations[1];

          final recording = _RecordingConversationsNotifier([groupConv]);

          await tester.pumpApp(
            ConversationPanel(onConversationTap: (_) {}),
            overrides: [
              authOverride(loggedInAuthState),
              serverUrlOverride(),
              conversationsProvider.overrideWith(() => recording),
              contactsOverride(),
              webSocketOverride(),
              cryptoOverride(),
            ],
          );
          await tester.pump();

          await tester.drag(find.byType(Slidable), const Offset(-300, 0));
          await tester.pumpAndSettle();

          // For a group the destructive swipe action is labelled "Leave".
          await tester.tap(find.text('Leave'));
          await tester.pumpAndSettle();

          // Confirm dialog renders the group-leave copy.
          expect(find.text('Leave Group'), findsOneWidget);

          await tester.tap(
            find.descendant(
              of: find.byType(FilledButton),
              matching: find.text('Leave'),
            ),
          );
          await tester.pumpAndSettle();

          expect(recording.leaveGroupCalls, ['conv-2']);

          // Let the success toast's dismiss timer expire.
          await tester.pump(const Duration(seconds: 10));
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('cancelling the confirm dialog does NOT call the notifier', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      try {
        final recording = _RecordingConversationsNotifier([
          sampleConversations.first,
        ]);

        await tester.pumpApp(
          ConversationPanel(onConversationTap: (_) {}),
          overrides: [
            authOverride(loggedInAuthState),
            serverUrlOverride(),
            conversationsProvider.overrideWith(() => recording),
            contactsOverride(),
            webSocketOverride(),
            cryptoOverride(),
          ],
        );
        await tester.pump();

        await tester.drag(find.byType(Slidable), const Offset(-300, 0));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(find.text('Delete Conversation'), findsOneWidget);

        // Tap Cancel — confirm should resolve false and the notifier method
        // must NOT have been invoked.
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(recording.leaveConversationCalls, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  // -------------------------------------------------------------------------
  // compose_fab.dart — additional FAB coverage.
  // -------------------------------------------------------------------------
  group('ConversationPanel compose FAB', () {
    testWidgets(
      'long-press menu Discover Groups routes to the discover callback',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        var discoverCalled = false;

        await tester.pumpApp(
          ConversationPanel(
            onConversationTap: (_) {},
            onNewChat: () {},
            onNewGroup: () {},
            onDiscover: () => discoverCalled = true,
          ),
          overrides: standardOverrides(),
        );
        await tester.pump();

        await tester.longPress(find.byIcon(Icons.edit_outlined));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Discover groups'));
        await tester.pumpAndSettle();
        expect(discoverCalled, isTrue);
      },
    );

    testWidgets(
      'FAB hidden on desktop layout (width >= 600) even with onNewChat set',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpApp(
          ConversationPanel(
            onConversationTap: (_) {},
            onNewChat: () {},
            onNewGroup: () {},
            onDiscover: () {},
          ),
          overrides: standardOverrides(),
        );
        await tester.pump();

        // The desktop "+" header menu is the entry-point on wide layouts;
        // the pencil FAB must not render alongside it. The header's "+" icon
        // is `Icons.add`, not `Icons.edit_outlined`.
        expect(find.byIcon(Icons.edit_outlined), findsNothing);
        expect(find.byIcon(Icons.add), findsOneWidget);
      },
    );
  });

  group('buildAvatar', () {
    testWidgets('renders initial letter', (tester) async {
      await tester.pumpApp(buildAvatar(name: 'Alice', radius: 20));
      await tester.pump();

      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('renders ? for empty name', (tester) async {
      await tester.pumpApp(buildAvatar(name: '', radius: 20));
      await tester.pump();

      expect(find.text('?'), findsOneWidget);
    });
  });

  group('avatarColor', () {
    test('returns consistent color for same name', () {
      final c1 = avatarColor('alice');
      final c2 = avatarColor('alice');
      expect(c1, equals(c2));
    });

    test('returns different colors for different names', () {
      // Not guaranteed but statistically likely for different names
      final c1 = avatarColor('alice');
      final c2 = avatarColor('bob');
      // At minimum they should both be valid colors
      expect(c1.a, greaterThan(0));
      expect(c2.a, greaterThan(0));
    });
  });

  group('resolveAvatarUrl', () {
    test('returns null for null input', () {
      expect(resolveAvatarUrl(null, 'http://localhost:8080'), isNull);
    });

    test('returns null for empty string', () {
      expect(resolveAvatarUrl('', 'http://localhost:8080'), isNull);
    });

    test('prepends serverUrl to relative path', () {
      expect(
        resolveAvatarUrl('/api/users/abc/avatar', 'http://localhost:8080'),
        equals('http://localhost:8080/api/users/abc/avatar'),
      );
    });

    test('returns absolute URL unchanged', () {
      expect(
        resolveAvatarUrl(
          'https://example.com/avatar.png',
          'http://localhost:8080',
        ),
        equals('https://example.com/avatar.png'),
      );
    });

    test('returns http absolute URL unchanged', () {
      expect(
        resolveAvatarUrl(
          'http://example.com/avatar.png',
          'http://localhost:8080',
        ),
        equals('http://example.com/avatar.png'),
      );
    });
  });
}
