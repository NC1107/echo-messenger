import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/conversations_provider.dart';
import 'package:echo_app/src/providers/privacy_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';

import '../helpers/mock_http_client.dart';

void main() {
  late MockHttpClient mockClient;
  late ProviderContainer container;

  setUpAll(() {
    registerHttpFallbackValues();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockClient = MockHttpClient();
    when(() => mockClient.close()).thenReturn(null);

    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith((ref) {
          final n = AuthNotifier(ref);
          n.state = const AuthState(
            isLoggedIn: true,
            userId: 'me',
            username: 'testuser',
            token: 'fake-token',
            refreshToken: 'fake-refresh',
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
      ],
    );
  });

  tearDown(() => container.dispose());

  /// Stub GET /api/conversations to return a list (used by loadConversations).
  void stubLoadConversations([List<Map<String, dynamic>> convs = const []]) {
    when(
      () => mockClient.get(
        any(that: predicate<Uri>((u) => u.path == '/api/conversations')),
        headers: any(named: 'headers'),
      ),
    ).thenAnswer((_) async => http.Response(jsonEncode(convs), 200));
  }

  group('ConversationsNotifier.createGroup', () {
    test('returns conversation ID on 201', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/groups')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async => http.Response('{"conversation_id": "new-group-id"}', 201),
      );
      stubLoadConversations();

      final notifier = container.read(conversationsProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.createGroup('Test Group', ['user-1', 'user-2']),
        () => mockClient,
      );

      expect(result, 'new-group-id');
    });

    test('returns null on failure', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/groups')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('{"error": "forbidden"}', 403));

      final notifier = container.read(conversationsProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.createGroup('Test', []),
        () => mockClient,
      );

      expect(result, isNull);
    });

    test('sends correct JSON body', () async {
      String? capturedBody;
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/groups')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((inv) async {
        capturedBody = inv.namedArguments[#body] as String?;
        return http.Response('{"conversation_id": "g1"}', 201);
      });
      stubLoadConversations();

      final notifier = container.read(conversationsProvider.notifier);
      await http.runWithClient(
        () => notifier.createGroup(
          'Dev Team',
          ['u1', 'u2'],
          description: 'Engineering',
          isPublic: true,
        ),
        () => mockClient,
      );

      expect(capturedBody, isNotNull);
      final parsed = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(parsed['name'], 'Dev Team');
      expect(parsed['member_ids'], ['u1', 'u2']);
      expect(parsed['description'], 'Engineering');
      expect(parsed['is_public'], isTrue);
    });
  });

  group('ConversationsNotifier.leaveGroup', () {
    test('returns true and removes conversation on success', () async {
      when(
        () => mockClient.post(
          any(
            that: predicate<Uri>((u) => u.path == '/api/groups/group-1/leave'),
          ),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));

      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [
          Conversation(id: 'group-1', name: 'G1', isGroup: true),
          Conversation(id: 'group-2', name: 'G2', isGroup: true),
        ],
      );

      final result = await http.runWithClient(
        () => notifier.leaveGroup('group-1'),
        () => mockClient,
      );

      expect(result, isTrue);
      expect(
        notifier.state.conversations.any((c) => c.id == 'group-1'),
        isFalse,
      );
      expect(notifier.state.conversations, hasLength(1));
    });

    test('returns false on failure', () async {
      when(
        () => mockClient.post(
          any(
            that: predicate<Uri>((u) => u.path == '/api/groups/group-1/leave'),
          ),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('error', 500));

      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [Conversation(id: 'group-1', name: 'G1', isGroup: true)],
      );

      final result = await http.runWithClient(
        () => notifier.leaveGroup('group-1'),
        () => mockClient,
      );

      expect(result, isFalse);
      // Conversation should still be there.
      expect(notifier.state.conversations, hasLength(1));
    });
  });

  group('ConversationsNotifier.leaveConversation', () {
    test('returns true and removes conversation on success', () async {
      when(
        () => mockClient.post(
          any(
            that: predicate<Uri>(
              (u) => u.path == '/api/conversations/conv-1/leave',
            ),
          ),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));

      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [Conversation(id: 'conv-1', isGroup: false)],
      );

      final result = await http.runWithClient(
        () => notifier.leaveConversation('conv-1'),
        () => mockClient,
      );

      expect(result, isTrue);
      expect(notifier.state.conversations, isEmpty);
    });
  });

  group('ConversationsNotifier.loadConversations', () {
    test('parses conversations on 200', () async {
      when(
        () => mockClient.get(
          any(that: predicate<Uri>((u) => u.path == '/api/conversations')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode([
            {
              'conversation_id': 'c1',
              'kind': 'group',
              'title': 'Team',
              'last_message': 'Hello',
              'last_message_timestamp': '2026-01-15T10:00:00Z',
              'unread_count': 3,
              'members': [],
            },
          ]),
          200,
        ),
      );

      final notifier = container.read(conversationsProvider.notifier);
      await http.runWithClient(
        () => notifier.loadConversations(),
        () => mockClient,
      );

      expect(notifier.state.conversations, hasLength(1));
      expect(notifier.state.conversations.first.name, 'Team');
      expect(notifier.state.conversations.first.unreadCount, 3);
      expect(notifier.state.isLoading, isFalse);
    });

    test('sets error on non-200', () async {
      when(
        () => mockClient.get(
          any(that: predicate<Uri>((u) => u.path == '/api/conversations')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('error', 500));

      final notifier = container.read(conversationsProvider.notifier);
      await http.runWithClient(
        () => notifier.loadConversations(),
        () => mockClient,
      );

      expect(notifier.state.error, isNotNull);
      expect(notifier.state.isLoading, isFalse);
    });

    // -------------------------------------------------------------------
    // #515: monotonic-generation guard against stale reload responses.
    // Two concurrent reloads (e.g. WS reconnect racing pull-to-refresh)
    // must NOT let the older response overwrite the newer one's state.
    // -------------------------------------------------------------------
    group('stale-guard (#515)', () {
      Map<String, dynamic> convFixture(String id, String title) => {
        'conversation_id': id,
        'kind': 'group',
        'title': title,
        'last_message': 'msg-$id',
        'last_message_timestamp': '2026-01-15T10:00:00Z',
        'unread_count': 0,
        'members': [],
      };

      test('late stale success does not overwrite fresh success', () async {
        // Two completers control response ordering on the same URL.
        final completers = <Completer<http.Response>>[
          Completer<http.Response>(),
          Completer<http.Response>(),
        ];
        var callIndex = 0;
        when(
          () => mockClient.get(
            any(that: predicate<Uri>((u) => u.path == '/api/conversations')),
            headers: any(named: 'headers'),
          ),
        ).thenAnswer((_) => completers[callIndex++].future);

        final notifier = container.read(conversationsProvider.notifier);
        await http.runWithClient(() async {
          // Fire two reloads back-to-back without awaiting.
          final a = notifier.loadConversations();
          final b = notifier.loadConversations();

          // Resolve B first with [convB], then A with [convA].
          completers[1].complete(
            http.Response(jsonEncode([convFixture('B', 'B')]), 200),
          );
          await b;
          completers[0].complete(
            http.Response(jsonEncode([convFixture('A', 'A')]), 200),
          );
          await a;

          // Latest call (B) must win even though A finished after.
          expect(notifier.state.conversations, hasLength(1));
          expect(notifier.state.conversations.first.id, 'B');
        }, () => mockClient);
      });

      test('late stale error does not clobber fresh success', () async {
        final completers = <Completer<http.Response>>[
          Completer<http.Response>(),
          Completer<http.Response>(),
        ];
        var callIndex = 0;
        when(
          () => mockClient.get(
            any(that: predicate<Uri>((u) => u.path == '/api/conversations')),
            headers: any(named: 'headers'),
          ),
        ).thenAnswer((_) => completers[callIndex++].future);

        final notifier = container.read(conversationsProvider.notifier);
        await http.runWithClient(() async {
          final a = notifier.loadConversations(); // will throw
          final b = notifier.loadConversations(); // succeeds

          completers[1].complete(
            http.Response(jsonEncode([convFixture('B', 'B')]), 200),
          );
          await b;
          completers[0].completeError(const SocketException('boom'));
          await a;

          // Stale error must NOT clobber fresh success state.
          expect(notifier.state.conversations, hasLength(1));
          expect(notifier.state.conversations.first.id, 'B');
          expect(notifier.state.error, isNull);
          expect(notifier.state.isLoading, isFalse);
        }, () => mockClient);
      });

      test('isLoading stays true until latest call completes', () async {
        final completers = <Completer<http.Response>>[
          Completer<http.Response>(),
          Completer<http.Response>(),
        ];
        var callIndex = 0;
        when(
          () => mockClient.get(
            any(that: predicate<Uri>((u) => u.path == '/api/conversations')),
            headers: any(named: 'headers'),
          ),
        ).thenAnswer((_) => completers[callIndex++].future);

        final notifier = container.read(conversationsProvider.notifier);
        await http.runWithClient(() async {
          final a = notifier.loadConversations();
          final b = notifier.loadConversations();

          // Mid-flight: at least one response still pending.
          expect(notifier.state.isLoading, isTrue);

          // Resolve the older call first; isLoading must stay true since
          // the latest is still in flight (and its response will be the
          // one that flips loading=false).
          completers[0].complete(
            http.Response(jsonEncode([convFixture('A', 'A')]), 200),
          );
          await a;
          expect(
            notifier.state.isLoading,
            isTrue,
            reason: 'stale return must not flip loading=false',
          );

          // Now resolve the latest call -- THIS one is allowed to clear it.
          completers[1].complete(
            http.Response(jsonEncode([convFixture('B', 'B')]), 200),
          );
          await b;
          expect(notifier.state.isLoading, isFalse);
          expect(notifier.state.conversations.first.id, 'B');
        }, () => mockClient);
      });
    });
  });

  group('ConversationsNotifier.getOrCreateDm', () {
    test('finds existing DM locally without HTTP call', () async {
      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [
          Conversation(
            id: 'dm-1',
            isGroup: false,
            members: [
              ConversationMember(userId: 'peer-1', username: 'alice'),
              ConversationMember(userId: 'me', username: 'testuser'),
            ],
          ),
        ],
      );

      final result = await http.runWithClient(
        () => notifier.getOrCreateDm('peer-1', 'alice'),
        () => mockClient,
      );

      expect(result.id, 'dm-1');
      // Verify no HTTP call was made.
      verifyNever(
        () => mockClient.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      );
    });

    test('creates via API when not found locally', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/conversations/dm')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async =>
            http.Response(jsonEncode({'conversation_id': 'new-dm-1'}), 200),
      );

      // Stub loadConversations to return the newly created DM.
      when(
        () => mockClient.get(
          any(that: predicate<Uri>((u) => u.path == '/api/conversations')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode([
            {
              'conversation_id': 'new-dm-1',
              'kind': 'direct',
              'members': [
                {'user_id': 'peer-1', 'username': 'alice'},
                {'user_id': 'me', 'username': 'testuser'},
              ],
            },
          ]),
          200,
        ),
      );

      final notifier = container.read(conversationsProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.getOrCreateDm('peer-1', 'alice'),
        () => mockClient,
      );

      expect(result.id, 'new-dm-1');
    });

    test('throws DmException when server returns 400', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/conversations/dm')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async => http.Response(jsonEncode({'error': 'Not a contact'}), 400),
      );

      final notifier = container.read(conversationsProvider.notifier);
      expect(
        () => http.runWithClient(
          () => notifier.getOrCreateDm('stranger-1', 'stranger'),
          () => mockClient,
        ),
        throwsA(isA<DmException>()),
      );
    });

    test('throws DmException on network error', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/conversations/dm')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenThrow(const SocketException('Connection refused'));

      final notifier = container.read(conversationsProvider.notifier);
      expect(
        () => http.runWithClient(
          () => notifier.getOrCreateDm('peer-1', 'alice'),
          () => mockClient,
        ),
        throwsA(
          isA<DmException>().having(
            (e) => e.message,
            'message',
            contains('connect'),
          ),
        ),
      );
    });
  });

  group('ConversationsNotifier.sendReadReceipt', () {
    test('success clears unread count', () async {
      when(
        () => mockClient.post(
          any(
            that: predicate<Uri>(
              (u) => u.path == '/api/conversations/conv-1/read',
            ),
          ),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));

      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [
          Conversation(id: 'conv-1', isGroup: false, unreadCount: 5),
        ],
      );

      await http.runWithClient(
        () => notifier.sendReadReceipt('conv-1'),
        () => mockClient,
      );

      expect(notifier.state.conversations.first.unreadCount, 0);
    });

    test('failure reverts unread count', () async {
      when(
        () => mockClient.post(
          any(
            that: predicate<Uri>(
              (u) => u.path == '/api/conversations/conv-1/read',
            ),
          ),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenThrow(const SocketException('Connection refused'));

      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [
          Conversation(id: 'conv-1', isGroup: false, unreadCount: 5),
        ],
      );

      await http.runWithClient(
        () => notifier.sendReadReceipt('conv-1'),
        () => mockClient,
      );

      expect(
        notifier.state.conversations.first.unreadCount,
        5,
        reason: 'unread count should be restored after server failure',
      );
    });
  });

  group('ConversationsNotifier.toggleMute', () {
    test('success toggles muted state', () async {
      when(
        () => mockClient.put(
          any(
            that: predicate<Uri>(
              (u) => u.path == '/api/conversations/conv-1/mute',
            ),
          ),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));

      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [
          Conversation(id: 'conv-1', isGroup: false, isMuted: false),
        ],
      );

      await http.runWithClient(
        () => notifier.toggleMute('conv-1'),
        () => mockClient,
      );

      expect(
        notifier.state.conversations.first.isMuted,
        isTrue,
        reason: 'conversation should be muted after toggle',
      );
    });

    test('failure reverts muted state', () async {
      when(
        () => mockClient.put(
          any(
            that: predicate<Uri>(
              (u) => u.path == '/api/conversations/conv-1/mute',
            ),
          ),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenThrow(const SocketException('Connection refused'));

      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [
          Conversation(id: 'conv-1', isGroup: false, isMuted: false),
        ],
      );

      await http.runWithClient(
        () => notifier.toggleMute('conv-1'),
        () => mockClient,
      );

      expect(
        notifier.state.conversations.first.isMuted,
        isFalse,
        reason: 'muted state should be reverted after server failure',
      );
    });
  });

  group('ConversationsNotifier.setMuted', () {
    test('optimistically mutes and keeps state on 200', () async {
      when(
        () => mockClient.put(
          any(
            that: predicate<Uri>(
              (u) => u.path == '/api/conversations/conv-1/mute',
            ),
          ),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));

      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [
          Conversation(id: 'conv-1', isGroup: false, isMuted: false),
        ],
      );

      final result = await http.runWithClient(
        () => notifier.setMuted('conv-1', true),
        () => mockClient,
      );

      expect(result, isTrue);
      expect(
        notifier.state.conversations.first.isMuted,
        isTrue,
        reason: 'conversation stays muted after server confirmation',
      );
    });

    test('reverts optimistic mute on server 500', () async {
      when(
        () => mockClient.put(
          any(
            that: predicate<Uri>(
              (u) => u.path == '/api/conversations/conv-1/mute',
            ),
          ),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('Internal Server Error', 500));

      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [
          Conversation(id: 'conv-1', isGroup: false, isMuted: false),
        ],
      );

      final result = await http.runWithClient(
        () => notifier.setMuted('conv-1', true),
        () => mockClient,
      );

      expect(result, isFalse);
      expect(
        notifier.state.conversations.first.isMuted,
        isFalse,
        reason: 'muted state reverted after server rejection',
      );
    });

    test('no-op returns true when already in target state', () async {
      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [
          Conversation(id: 'conv-1', isGroup: false, isMuted: true),
        ],
      );

      final result = await http.runWithClient(
        () => notifier.setMuted('conv-1', true),
        () => mockClient,
      );

      expect(result, isTrue);
      // Verify no HTTP request was made.
      verifyNever(
        () => mockClient.put(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      );
    });

    test('returns false for unknown conversation id', () async {
      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState();

      final result = await http.runWithClient(
        () => notifier.setMuted('no-such-conv', true),
        () => mockClient,
      );

      expect(result, isFalse);
    });
  });

  group('ConversationsNotifier.toggleMute extra', () {
    test('returns false for unknown conversation id', () async {
      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState();

      final result = await http.runWithClient(
        () => notifier.toggleMute('no-such-conv'),
        () => mockClient,
      );

      expect(result, isFalse);
    });
  });

  group('ConversationsNotifier.setPinned', () {
    test('optimistically pins and keeps state on 204', () async {
      when(
        () => mockClient.put(
          any(
            that: predicate<Uri>(
              (u) => u.path == '/api/conversations/conv-1/pin',
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('', 204));

      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [
          Conversation(id: 'conv-1', isGroup: false, isPinned: false),
        ],
      );

      final result = await http.runWithClient(
        () => notifier.setPinned('conv-1', true),
        () => mockClient,
      );

      expect(result, isTrue);
      expect(
        notifier.state.conversations.first.isPinned,
        isTrue,
        reason: 'conversation stays pinned after server confirmation',
      );
    });

    test('reverts optimistic pin on server 500', () async {
      when(
        () => mockClient.put(
          any(
            that: predicate<Uri>(
              (u) => u.path == '/api/conversations/conv-1/pin',
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('Internal Server Error', 500));

      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [
          Conversation(id: 'conv-1', isGroup: false, isPinned: false),
        ],
      );

      final result = await http.runWithClient(
        () => notifier.setPinned('conv-1', true),
        () => mockClient,
      );

      expect(result, isFalse);
      expect(
        notifier.state.conversations.first.isPinned,
        isFalse,
        reason: 'pinned state reverted after server rejection',
      );
    });

    test('sends DELETE to unpin conversation', () async {
      Uri? capturedUri;
      when(
        () => mockClient.delete(
          any(
            that: predicate<Uri>(
              (u) => u.path == '/api/conversations/conv-1/pin',
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((inv) async {
        capturedUri = inv.positionalArguments.first as Uri;
        return http.Response('', 204);
      });

      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [
          Conversation(id: 'conv-1', isGroup: false, isPinned: true),
        ],
      );

      final result = await http.runWithClient(
        () => notifier.setPinned('conv-1', false),
        () => mockClient,
      );

      expect(result, isTrue);
      expect(capturedUri?.path, '/api/conversations/conv-1/pin');
      expect(
        notifier.state.conversations.first.isPinned,
        isFalse,
        reason: 'conversation unpinned after server confirmation',
      );
    });

    test('reverts optimistic unpin on server failure', () async {
      when(
        () => mockClient.delete(
          any(
            that: predicate<Uri>(
              (u) => u.path == '/api/conversations/conv-1/pin',
            ),
          ),
          headers: any(named: 'headers'),
        ),
      ).thenThrow(const SocketException('Connection refused'));

      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [
          Conversation(id: 'conv-1', isGroup: false, isPinned: true),
        ],
      );

      final result = await http.runWithClient(
        () => notifier.setPinned('conv-1', false),
        () => mockClient,
      );

      expect(result, isFalse);
      expect(
        notifier.state.conversations.first.isPinned,
        isTrue,
        reason: 'pinned state reverted after network failure',
      );
    });

    test('no-op returns true when already in target state', () async {
      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState(
        conversations: [
          Conversation(id: 'conv-1', isGroup: false, isPinned: true),
        ],
      );

      final result = await http.runWithClient(
        () => notifier.setPinned('conv-1', true),
        () => mockClient,
      );

      expect(result, isTrue);
      // No HTTP call should have been made.
      verifyNever(() => mockClient.put(any(), headers: any(named: 'headers')));
      verifyNever(
        () => mockClient.delete(any(), headers: any(named: 'headers')),
      );
    });

    test('returns false for unknown conversation id', () async {
      final notifier = container.read(conversationsProvider.notifier);
      notifier.state = const ConversationsState();

      final result = await http.runWithClient(
        () => notifier.setPinned('no-such-conv', true),
        () => mockClient,
      );

      expect(result, isFalse);
    });
  });
}
