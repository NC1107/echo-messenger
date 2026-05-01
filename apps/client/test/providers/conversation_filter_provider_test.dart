import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/conversation_filter_provider.dart';
import 'package:echo_app/src/providers/conversations_provider.dart';
import 'package:echo_app/src/providers/privacy_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a minimal [Conversation] for testing.
Conversation _conv({
  required String id,
  required String name,
  bool isGroup = false,
  bool isPinned = false,
  String? lastMessageTimestamp,
  String? lastMessage,
}) {
  return Conversation(
    id: id,
    name: name,
    isGroup: isGroup,
    isPinned: isPinned,
    lastMessageTimestamp: lastMessageTimestamp,
    lastMessage: lastMessage,
  );
}

/// Creates a [ProviderContainer] pre-seeded with [conversations] and optional
/// overrides for filter / search / pinned state.
ProviderContainer _container({
  required List<Conversation> conversations,
  String searchQuery = '',
  ConversationFilterType filterType = ConversationFilterType.all,
  Set<String> pinnedIds = const {},
}) {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith((ref) {
        final n = AuthNotifier(ref);
        n.state = const AuthState(
          isLoggedIn: true,
          userId: 'me',
          username: 'testuser',
          token: 'fake-token',
        );
        return n;
      }),
      serverUrlProvider.overrideWith((ref) {
        final n = ServerUrlNotifier();
        n.state = 'http://localhost:8080';
        return n;
      }),
      privacyProvider.overrideWith((ref) {
        final n = PrivacyNotifier(ref);
        n.state = const PrivacyState();
        return n;
      }),
      conversationSearchQueryProvider.overrideWith((ref) => searchQuery),
      conversationFilterTypeProvider.overrideWith((ref) => filterType),
      pinnedConversationIdsProvider.overrideWith((ref) => pinnedIds),
    ],
  );
  // Seed conversations directly into state (no network call needed).
  container.read(conversationsProvider.notifier).state = ConversationsState(
    conversations: conversations,
  );
  addTearDown(container.dispose);
  return container;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('sortedConversationsProvider', () {
    // ------------------------------------------------------------------
    // Ordering
    // ------------------------------------------------------------------
    test('returns conversations sorted newest-first by default', () {
      final convs = [
        _conv(
          id: 'a',
          name: 'Alice',
          lastMessageTimestamp: '2024-01-01T10:00:00Z',
        ),
        _conv(
          id: 'b',
          name: 'Bob',
          lastMessageTimestamp: '2024-01-03T08:00:00Z',
        ),
        _conv(
          id: 'c',
          name: 'Charlie',
          lastMessageTimestamp: '2024-01-02T15:00:00Z',
        ),
      ];
      final container = _container(conversations: convs);
      final result = container.read(sortedConversationsProvider);

      expect(result.map((c) => c.id).toList(), ['b', 'c', 'a']);
    });

    // ------------------------------------------------------------------
    // Pin grouping
    // ------------------------------------------------------------------
    test('pinned conversations appear before unpinned', () {
      final convs = [
        _conv(
          id: 'unpinned1',
          name: 'A',
          lastMessageTimestamp: '2024-01-05T00:00:00Z',
        ),
        _conv(
          id: 'pinned1',
          name: 'B',
          lastMessageTimestamp: '2024-01-01T00:00:00Z',
        ),
        _conv(
          id: 'unpinned2',
          name: 'C',
          lastMessageTimestamp: '2024-01-03T00:00:00Z',
        ),
      ];
      final container = _container(
        conversations: convs,
        pinnedIds: {'pinned1'},
      );
      final result = container.read(sortedConversationsProvider);

      expect(result.first.id, 'pinned1');
      // Remaining two are ordered newest-first.
      expect(result[1].id, 'unpinned1');
      expect(result[2].id, 'unpinned2');
    });

    test('multiple pinned conversations sorted by timestamp within group', () {
      final convs = [
        _conv(
          id: 'p1',
          name: 'P1',
          isPinned: true,
          lastMessageTimestamp: '2024-01-02T00:00:00Z',
        ),
        _conv(
          id: 'p2',
          name: 'P2',
          isPinned: true,
          lastMessageTimestamp: '2024-01-04T00:00:00Z',
        ),
        _conv(
          id: 'u1',
          name: 'U1',
          lastMessageTimestamp: '2024-01-03T00:00:00Z',
        ),
      ];
      final container = _container(conversations: convs);
      final result = container.read(sortedConversationsProvider);

      // p2 (newer) comes before p1 in the pinned group.
      expect(result[0].id, 'p2');
      expect(result[1].id, 'p1');
      expect(result[2].id, 'u1');
    });

    test('server isPinned flag also pins without a local pinnedIds entry', () {
      final convs = [
        _conv(id: 'p', name: 'Pinned', isPinned: true),
        _conv(id: 'u', name: 'Unpinned'),
      ];
      // No pinnedIds override — relies solely on Conversation.isPinned.
      final container = _container(conversations: convs);
      final result = container.read(sortedConversationsProvider);

      expect(result.first.id, 'p');
    });

    // ------------------------------------------------------------------
    // Type filter
    // ------------------------------------------------------------------
    test('DMs filter returns only non-group conversations', () {
      final convs = [
        _conv(id: 'dm1', name: 'Alice'),
        _conv(id: 'g1', name: 'Team', isGroup: true),
        _conv(id: 'dm2', name: 'Bob'),
      ];
      final container = _container(
        conversations: convs,
        filterType: ConversationFilterType.dms,
      );
      final result = container.read(sortedConversationsProvider);

      expect(result.every((c) => !c.isGroup), isTrue);
      expect(result.map((c) => c.id), containsAll(['dm1', 'dm2']));
      expect(result.any((c) => c.id == 'g1'), isFalse);
    });

    test('Groups filter returns only group conversations', () {
      final convs = [
        _conv(id: 'dm1', name: 'Alice'),
        _conv(id: 'g1', name: 'Team', isGroup: true),
        _conv(id: 'g2', name: 'Dev', isGroup: true),
      ];
      final container = _container(
        conversations: convs,
        filterType: ConversationFilterType.groups,
      );
      final result = container.read(sortedConversationsProvider);

      expect(result.every((c) => c.isGroup), isTrue);
      expect(result.length, 2);
    });

    test('All filter returns all conversations', () {
      final convs = [
        _conv(id: 'dm1', name: 'Alice'),
        _conv(id: 'g1', name: 'Team', isGroup: true),
      ];
      final container = _container(conversations: convs);
      final result = container.read(sortedConversationsProvider);
      expect(result.length, 2);
    });

    // ------------------------------------------------------------------
    // Fuzzy search
    // ------------------------------------------------------------------
    test('search query filters by name relevance', () {
      final convs = [
        _conv(id: 'a', name: 'Alice Smith'),
        _conv(id: 'b', name: 'Bob Jones'),
        _conv(id: 'c', name: 'Charlie Brown'),
      ];
      final container = _container(conversations: convs, searchQuery: 'alice');
      final result = container.read(sortedConversationsProvider);

      expect(result.length, 1);
      expect(result.first.id, 'a');
    });

    test('search returns empty list when nothing matches', () {
      final convs = [
        _conv(id: 'a', name: 'Alice'),
        _conv(id: 'b', name: 'Bob'),
      ];
      final container = _container(conversations: convs, searchQuery: 'zzz');
      final result = container.read(sortedConversationsProvider);

      expect(result, isEmpty);
    });

    test('search skips pin-first sort and uses relevance order', () {
      final convs = [
        _conv(id: 'bob', name: 'Bob'),
        _conv(id: 'alice', name: 'Alice', isPinned: true),
      ];
      // Search for "bob" — Alice is pinned but relevance order wins.
      final container = _container(conversations: convs, searchQuery: 'bob');
      final result = container.read(sortedConversationsProvider);

      expect(result.length, 1);
      expect(result.first.id, 'bob');
    });

    // ------------------------------------------------------------------
    // Edge cases
    // ------------------------------------------------------------------
    test('returns empty list when there are no conversations', () {
      final container = _container(conversations: []);
      final result = container.read(sortedConversationsProvider);
      expect(result, isEmpty);
    });

    test('single conversation is returned as-is', () {
      final container = _container(
        conversations: [_conv(id: 'only', name: 'Only One')],
      );
      final result = container.read(sortedConversationsProvider);
      expect(result.length, 1);
      expect(result.first.id, 'only');
    });

    test('muted conversations are still included (mute does not filter)', () {
      final convs = [
        const Conversation(
          id: 'muted',
          name: 'Muted Chat',
          isGroup: false,
          isMuted: true,
        ),
        _conv(id: 'normal', name: 'Normal Chat'),
      ];
      final container = _container(conversations: convs);
      final result = container.read(sortedConversationsProvider);
      expect(result.length, 2);
    });
  });
}
