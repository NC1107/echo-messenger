// Widget tests for the freshly-split `group_info_screen` parts (header,
// members, channels, invite, disappearing-messages, danger-actions,
// add-member-dialog). The screen reads from `conversationsProvider` first
// and only falls back to HTTP when the conversation isn't already in
// state, so the tests seed the provider with a known group and never
// touch the network on initial render.
//
// What is not covered here:
//   - Avatar upload flow (needs `image_picker` and `showAvatarCropDialog`).
//   - Outgoing HTTP submissions (name / description save, kick, ban, leave,
//     delete, invite POST, TTL PUT, add-member POST). These call `http.put`
//     / `http.post` / `http.delete` directly and would need
//     `http.runWithClient` plumbing for every action. The tests instead
//     assert the pre-network UI state: the right dialog opens, the right
//     confirm prompt fires, the right contact list is rendered, etc.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:echo_app/src/models/channel.dart';
import 'package:echo_app/src/models/contact.dart';
import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/channels_provider.dart';
import 'package:echo_app/src/providers/contacts_provider.dart';
import 'package:echo_app/src/screens/group_info_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const _myUserId = 'test-user-id';

const _alice = ConversationMember(
  userId: 'user-alice',
  username: 'alice',
  role: 'admin',
);
const _bob = ConversationMember(
  userId: 'user-bob',
  username: 'bob',
  role: 'member',
);
const _carol = ConversationMember(
  userId: 'user-carol',
  username: 'carol',
  role: 'member',
);
const _ownerSelf = ConversationMember(
  userId: _myUserId,
  username: 'testuser',
  role: 'owner',
);
const _memberSelf = ConversationMember(
  userId: _myUserId,
  username: 'testuser',
  role: 'member',
);

const _ownerGroup = Conversation(
  id: 'group-1',
  name: 'Core Team',
  description: 'Internal coordination',
  isGroup: true,
  members: [_ownerSelf, _alice, _bob, _carol],
);

const _memberGroup = Conversation(
  id: 'group-2',
  name: 'Outsider Lounge',
  isGroup: true,
  members: [
    ConversationMember(
      userId: 'user-owner',
      username: 'owneruser',
      role: 'owner',
    ),
    _memberSelf,
    _bob,
  ],
);

const _contactDave = Contact(
  id: 'c-dave',
  userId: 'user-dave',
  username: 'dave',
  displayName: 'Dave D',
  status: 'accepted',
);
const _contactErin = Contact(
  id: 'c-erin',
  userId: 'user-erin',
  username: 'erin',
  displayName: 'Erin E',
  status: 'accepted',
);
// Bob is already a member; should be filtered out of the picker.
const _contactBob = Contact(
  id: 'c-bob',
  userId: 'user-bob',
  username: 'bob',
  displayName: 'Bob B',
  status: 'accepted',
);

// ---------------------------------------------------------------------------
// Fake notifiers
// ---------------------------------------------------------------------------

class _FakeChannels extends Channels {
  _FakeChannels({List<GroupChannel> initial = const []}) : _initial = initial;

  final List<GroupChannel> _initial;
  int createCallCount = 0;
  int deleteCallCount = 0;
  String? lastCreatedName;
  String? lastCreatedKind;
  String? lastDeletedId;

  @override
  ChannelsState build() => ChannelsState(
    channelsByConversation: _initial.isEmpty
        ? const {}
        : {_initial.first.conversationId: _initial},
  );

  @override
  Future<void> loadChannels(String conversationId) async {}

  @override
  Future<bool> createChannel(
    String conversationId,
    String name,
    String kind, {
    int? position,
  }) async {
    createCallCount++;
    lastCreatedName = name;
    lastCreatedKind = kind;
    return true;
  }

  @override
  Future<bool> deleteChannel(String conversationId, String channelId) async {
    deleteCallCount++;
    lastDeletedId = channelId;
    return true;
  }
}

class _FakeContactsSeeded extends Contacts {
  _FakeContactsSeeded(this._contacts);
  final List<Contact> _contacts;

  @override
  ContactsState build() => ContactsState(contacts: _contacts);

  @override
  Future<void> loadContacts() async {}

  @override
  Future<void> loadPending({bool force = false}) async {}
}

// ---------------------------------------------------------------------------
// Pump helpers
// ---------------------------------------------------------------------------

GoRouter _buildRouter(Conversation conv) {
  return GoRouter(
    initialLocation: '/group/${conv.id}',
    routes: [
      GoRoute(
        path: '/group/:id',
        builder: (_, state) =>
            GroupInfoScreen(conversationId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/home',
        builder: (_, _) =>
            const Scaffold(body: Center(child: Text('HOME_SCREEN'))),
      ),
    ],
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required Conversation conv,
  List<GroupChannel> channels = const [],
  List<Contact> contacts = const [],
  Size size = const Size(500, 2400), // narrow layout, tall surface so all
  // sections (header → channels → disappearing → danger zone) render in
  // the same viewport without needing a scroll-to-bring-into-view.
}) async {
  await tester.binding.setSurfaceSize(size);
  final router = _buildRouter(conv);
  final channelsNotifier = _FakeChannels(initial: channels);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...standardOverrides(conversations: [conv]),
        channelsProvider.overrideWith(() => channelsNotifier),
        contactsProvider.overrideWith(() => _FakeContactsSeeded(contacts)),
      ],
      child: MaterialApp.router(
        theme: EchoTheme.darkTheme,
        darkTheme: EchoTheme.darkTheme,
        themeMode: ThemeMode.dark,
        routerConfig: router,
      ),
    ),
  );
  // initState schedules a post-frame _loadGroupInfo; pump once to run it,
  // then once more to settle the resulting setState.
  await tester.pump();
  await tester.pump();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUp(() {
    // Reset the system clipboard between tests so invite-link assertions
    // don't see stale data.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            return null;
          }
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': ''};
          }
          return null;
        });
  });

  // -------------------------------------------------------------------------
  // header_section
  // -------------------------------------------------------------------------

  group('header_section', () {
    testWidgets('renders the group name from the conversation', (tester) async {
      await _pump(tester, conv: _ownerGroup);
      expect(find.text('Core Team'), findsOneWidget);
    });

    testWidgets('renders the description', (tester) async {
      await _pump(tester, conv: _ownerGroup);
      expect(find.text('Internal coordination'), findsOneWidget);
    });

    testWidgets('shows the "Edit group name" pencil for owner/admin', (
      tester,
    ) async {
      await _pump(tester, conv: _ownerGroup);
      expect(
        find.byTooltip('Edit group name'),
        findsOneWidget,
        reason: 'owner should see the pencil',
      );
    });

    testWidgets('hides the "Edit group name" pencil for non-admin', (
      tester,
    ) async {
      await _pump(tester, conv: _memberGroup);
      expect(find.byTooltip('Edit group name'), findsNothing);
    });

    testWidgets('tapping the pencil opens an inline name editor', (
      tester,
    ) async {
      await _pump(tester, conv: _ownerGroup);
      await tester.tap(find.byTooltip('Edit group name'));
      await tester.pump();

      // Inline editor exposes Save / Cancel affordances.
      expect(find.byTooltip('Save group name'), findsOneWidget);
      expect(find.byTooltip('Cancel editing'), findsOneWidget);
      // The text field is pre-filled with the current name.
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Core Team'),
      );
      expect(field.controller?.text, 'Core Team');
    });

    testWidgets('description pencil opens the description editor', (
      tester,
    ) async {
      await _pump(tester, conv: _ownerGroup);
      await tester.tap(find.byTooltip('Edit description'));
      await tester.pump();

      expect(find.byTooltip('Save description'), findsOneWidget);
    });

    testWidgets('renders the member count line ("4 members")', (tester) async {
      await _pump(tester, conv: _ownerGroup);
      // The string also appears as the section header for the roster, so
      // a couple of matches is expected — we just want at least one.
      expect(find.text('4 members'), findsWidgets);
    });

    testWidgets('falls back to "No description" when blank', (tester) async {
      const blank = Conversation(
        id: 'group-3',
        name: 'Empty Notes',
        isGroup: true,
        members: [_ownerSelf, _alice],
      );
      await _pump(tester, conv: blank);
      expect(find.text('No description'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // members_section
  // -------------------------------------------------------------------------

  group('members_section', () {
    testWidgets('renders roster grouped by role with counts', (tester) async {
      await _pump(tester, conv: _ownerGroup);

      // _ownerGroup has 1 owner, 1 admin, 2 regulars.
      expect(find.text('OWNER — 1'), findsOneWidget);
      expect(find.text('ADMIN — 1'), findsOneWidget);
      expect(find.text('MEMBERS — 2'), findsOneWidget);

      // Roster shows the usernames.
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('bob'), findsOneWidget);
      expect(find.text('carol'), findsOneWidget);
    });

    testWidgets('hides empty role sections', (tester) async {
      const onlyMembers = Conversation(
        id: 'group-4',
        name: 'Flat',
        isGroup: true,
        members: [_ownerSelf, _bob, _carol],
      );
      await _pump(tester, conv: onlyMembers);
      // No admins — the ADMIN header should not render.
      expect(find.textContaining('ADMIN'), findsNothing);
      expect(find.text('OWNER — 1'), findsOneWidget);
      expect(find.text('MEMBERS — 2'), findsOneWidget);
    });

    testWidgets('admin sees a "..." actions button on other members', (
      tester,
    ) async {
      await _pump(tester, conv: _ownerGroup);
      // alice + bob + carol → 3 action buttons (self is skipped).
      expect(find.byTooltip('Member actions'), findsNWidgets(3));
    });

    testWidgets('add-member trigger icon is visible', (tester) async {
      await _pump(tester, conv: _ownerGroup);
      expect(find.byTooltip('Add member'), findsOneWidget);
    });

    testWidgets('non-admin still sees the roster but no kick affordance', (
      tester,
    ) async {
      await _pump(tester, conv: _memberGroup);
      // _memberGroup has owner + self + bob. Non-admin viewer still gets
      // a "..." on other rows (the menu items just won't include kick/ban),
      // and there should be no inline "Remove" / "Ban" buttons in the
      // rendered tree.
      expect(find.text('Remove'), findsNothing);
      expect(find.text('Ban'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // channels_section
  // -------------------------------------------------------------------------

  group('channels_section', () {
    const generalChannel = GroupChannel(
      id: 'ch-1',
      conversationId: 'group-1',
      name: 'general',
      kind: 'text',
      position: 0,
      createdAt: '2026-01-01T00:00:00Z',
    );
    const voiceChannel = GroupChannel(
      id: 'ch-2',
      conversationId: 'group-1',
      name: 'lounge',
      kind: 'voice',
      position: 1,
      createdAt: '2026-01-01T00:00:00Z',
    );

    testWidgets('renders text and voice channels for admin', (tester) async {
      await _pump(
        tester,
        conv: _ownerGroup,
        channels: const [generalChannel, voiceChannel],
      );
      expect(find.text('general'), findsOneWidget);
      expect(find.text('lounge'), findsOneWidget);
      expect(find.text('Channels'), findsOneWidget);
    });

    testWidgets('admin sees the add-channel button', (tester) async {
      await _pump(tester, conv: _ownerGroup);
      expect(find.byTooltip('Add channel'), findsOneWidget);
    });

    testWidgets('non-admin does not see the channels section', (tester) async {
      await _pump(tester, conv: _memberGroup);
      expect(find.text('Channels'), findsNothing);
      expect(find.byTooltip('Add channel'), findsNothing);
    });

    testWidgets('tapping add-channel opens the Add channel dialog', (
      tester,
    ) async {
      await _pump(tester, conv: _ownerGroup);
      await tester.tap(find.byTooltip('Add channel'));
      await tester.pumpAndSettle();

      expect(find.text('Add channel'), findsOneWidget);
      expect(find.widgetWithText(TextField, ''), findsOneWidget);
      expect(find.text('Create'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('tapping delete on a channel opens the destructive confirm', (
      tester,
    ) async {
      await _pump(tester, conv: _ownerGroup, channels: const [generalChannel]);
      await tester.tap(find.byTooltip('Delete channel'));
      await tester.pumpAndSettle();

      expect(find.text('Delete Channel'), findsOneWidget);
      expect(find.textContaining('Delete channel "general"'), findsOneWidget);
      // The destructive confirm uses the danger colour on the title.
      final title = tester.widget<Text>(find.text('Delete Channel'));
      expect(title.style?.color, EchoTheme.danger);
    });
  });

  // -------------------------------------------------------------------------
  // invite_section
  // -------------------------------------------------------------------------

  group('invite_section', () {
    testWidgets('renders a "Copy Invite Link" button', (tester) async {
      await _pump(tester, conv: _ownerGroup);
      expect(find.text('Copy Invite Link'), findsOneWidget);
      expect(find.byIcon(Icons.link_outlined), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // disappearing_messages
  // -------------------------------------------------------------------------

  group('disappearing_messages', () {
    testWidgets('shows the section header for admins', (tester) async {
      await _pump(tester, conv: _ownerGroup);
      expect(find.text('Disappearing Messages'), findsOneWidget);
      expect(find.text('Auto-delete after'), findsOneWidget);
    });

    testWidgets('opens the dropdown with all TTL options', (tester) async {
      await _pump(tester, conv: _ownerGroup);
      await tester.tap(find.text('Auto-delete after'));
      await tester.pump();
      // Tap the dropdown button itself (the trailing "Off" label).
      await tester.tap(find.byType(DropdownButton<int?>));
      await tester.pumpAndSettle();

      // Each option from `_kTtlOptions` should appear in the open menu.
      // The "Off" label is also in the dropdown closed state, so allow >=1.
      expect(find.text('Off'), findsWidgets);
      expect(find.text('30 seconds'), findsOneWidget);
      expect(find.text('5 minutes'), findsOneWidget);
      expect(find.text('1 hour'), findsOneWidget);
      expect(find.text('1 day'), findsOneWidget);
      expect(find.text('1 week'), findsOneWidget);
    });

    testWidgets('non-admin does not see the TTL picker', (tester) async {
      await _pump(tester, conv: _memberGroup);
      expect(find.text('Disappearing Messages'), findsNothing);
      expect(find.text('Auto-delete after'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // danger_actions
  // -------------------------------------------------------------------------

  group('danger_actions', () {
    testWidgets('renders the Leave Group button', (tester) async {
      await _pump(tester, conv: _memberGroup);
      expect(find.text('Leave Group'), findsOneWidget);
    });

    testWidgets('owner sees the Danger Zone with Delete Group', (tester) async {
      await _pump(tester, conv: _ownerGroup);
      expect(find.text('Danger Zone'), findsOneWidget);
      expect(find.text('Delete Group'), findsOneWidget);
    });

    testWidgets('non-owner does NOT see the Danger Zone', (tester) async {
      await _pump(tester, conv: _memberGroup);
      expect(find.text('Danger Zone'), findsNothing);
      expect(find.text('Delete Group'), findsNothing);
    });

    testWidgets('tapping Leave Group fires the destructive confirm', (
      tester,
    ) async {
      await _pump(tester, conv: _memberGroup);
      await tester.tap(find.text('Leave Group'));
      await tester.pumpAndSettle();

      expect(find.text('Leave Group'), findsWidgets);
      expect(
        find.text('Are you sure you want to leave this group?'),
        findsOneWidget,
      );
      // Destructive variant: title is red.
      final title = tester
          .widgetList<Text>(find.text('Leave Group'))
          .firstWhere((t) => t.style?.color == EchoTheme.danger);
      expect(title.style?.color, EchoTheme.danger);
      // Confirm button is labelled "Leave".
      expect(find.widgetWithText(FilledButton, 'Leave'), findsOneWidget);
    });

    testWidgets('tapping Delete Group fires the destructive confirm', (
      tester,
    ) async {
      await _pump(tester, conv: _ownerGroup);
      await tester.tap(find.text('Delete Group'));
      await tester.pumpAndSettle();

      // The confirm dialog quotes the group name in its prompt.
      expect(find.textContaining('"Core Team"'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Delete'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // add_member_dialog
  // -------------------------------------------------------------------------

  group('add_member_dialog', () {
    testWidgets('opens with available contacts (excludes existing members)', (
      tester,
    ) async {
      await _pump(
        tester,
        conv: _ownerGroup,
        contacts: const [_contactDave, _contactErin, _contactBob],
      );
      await tester.tap(find.byTooltip('Add member'));
      await tester.pumpAndSettle();

      expect(find.text('Add Member'), findsOneWidget);
      // Dave and Erin are not group members → shown.
      expect(find.text('Dave D'), findsOneWidget);
      expect(find.text('Erin E'), findsOneWidget);
      // Bob is already in the group → filtered out.
      expect(find.text('Bob B'), findsNothing);
    });

    testWidgets('typing in the search field filters the contact list', (
      tester,
    ) async {
      await _pump(
        tester,
        conv: _ownerGroup,
        contacts: const [_contactDave, _contactErin],
      );
      await tester.tap(find.byTooltip('Add member'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Search contacts...'),
        'dave',
      );
      await tester.pump();

      expect(find.text('Dave D'), findsOneWidget);
      expect(find.text('Erin E'), findsNothing);
    });

    testWidgets('shows "No contacts found" when query matches nothing', (
      tester,
    ) async {
      await _pump(tester, conv: _ownerGroup, contacts: const [_contactDave]);
      await tester.tap(find.byTooltip('Add member'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Search contacts...'),
        'zzzzzzzz',
      );
      await tester.pump();

      expect(find.text('No contacts found'), findsOneWidget);
    });
  });
}
