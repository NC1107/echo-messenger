import 'dart:io';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/services/message_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Helper to build a minimal [ChatMessage] for cache tests.
ChatMessage _msg({
  required String id,
  String conversationId = 'conv-1',
  String content = 'hello',
  String fromUserId = 'sender-1',
  String timestamp = '2025-01-01T00:00:00Z',
}) {
  return ChatMessage(
    id: id,
    fromUserId: fromUserId,
    fromUsername: 'test-user',
    conversationId: conversationId,
    content: content,
    timestamp: timestamp,
    isMine: false,
  );
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('hive_cache_test_');
    Hive.init(tempDir.path);
    await MessageCache.init();
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('MessageCache.initForUser', () {
    test('is idempotent -- second call with same user is a no-op', () async {
      await MessageCache.initForUser('user-1', 'example.com');
      // Second call should return immediately without error.
      await MessageCache.initForUser('user-1', 'example.com');
    });

    test('switches between users and isolates cached data', () async {
      await MessageCache.initForUser('user-a', 'example.com');
      final msg = _msg(id: 'msg-switch-1');
      await MessageCache.cacheMessages('conv-1', [msg]);

      // Verify cached for user-a.
      expect(
        MessageCache.getCachedMessage('conv-1', 'msg-switch-1', 'user-a'),
        isNotNull,
      );

      // Switch to user-b -- cache should be empty.
      await MessageCache.initForUser('user-b', 'example.com');
      expect(
        MessageCache.getCachedMessage('conv-1', 'msg-switch-1', 'user-b'),
        isNull,
      );

      // Switch back to user-a -- data should still be there.
      await MessageCache.initForUser('user-a', 'example.com');
      expect(
        MessageCache.getCachedMessage('conv-1', 'msg-switch-1', 'user-a'),
        isNotNull,
      );
    });
  });

  group('MessageCache.cacheMessages', () {
    test('skips failure sentinels', () async {
      await MessageCache.initForUser('user-sentinels', 'example.com');

      final sentinels = [
        '[Message encrypted - history unavailable]',
        '[Encrypted history]',
        '[Could not decrypt - encryption keys may be out of sync]',
      ];

      for (var i = 0; i < sentinels.length; i++) {
        final msg = _msg(id: 'sentinel-$i', content: sentinels[i]);
        await MessageCache.cacheMessages('conv-1', [msg]);
        expect(
          MessageCache.getCachedMessage(
            'conv-1',
            'sentinel-$i',
            'user-sentinels',
          ),
          isNull,
          reason: 'sentinel "${sentinels[i]}" should not be cached',
        );
      }
    });

    test('skips pending_ messages', () async {
      await MessageCache.initForUser('user-pending', 'example.com');
      final msg = _msg(id: 'pending_xyz', content: 'real content');
      await MessageCache.cacheMessages('conv-1', [msg]);
      expect(
        MessageCache.getCachedMessage('conv-1', 'pending_xyz', 'user-pending'),
        isNull,
      );
    });

    test('caches normal messages', () async {
      await MessageCache.initForUser('user-normal', 'example.com');
      final msg = _msg(id: 'msg-normal-1', content: 'hi there');
      await MessageCache.cacheMessages('conv-1', [msg]);
      final cached = MessageCache.getCachedMessage(
        'conv-1',
        'msg-normal-1',
        'user-normal',
      );
      expect(cached, isNotNull);
      expect(cached!.content, 'hi there');
    });
  });

  group('MessageCache.getLatestCachedPreview', () {
    test('returns the most recent message content', () async {
      await MessageCache.initForUser('user-preview', 'example.com');
      await MessageCache.cacheMessages('conv-preview', [
        _msg(
          id: 'old',
          conversationId: 'conv-preview',
          content: 'old message',
          timestamp: '2025-01-01T00:00:00Z',
        ),
        _msg(
          id: 'mid',
          conversationId: 'conv-preview',
          content: 'mid message',
          timestamp: '2025-06-01T00:00:00Z',
        ),
        _msg(
          id: 'new',
          conversationId: 'conv-preview',
          content: 'new message',
          timestamp: '2025-12-01T00:00:00Z',
        ),
      ]);

      final preview = MessageCache.getLatestCachedPreview('conv-preview');
      expect(preview, 'new message');
    });

    test('returns null for unknown conversation', () async {
      await MessageCache.initForUser('user-preview2', 'example.com');
      expect(MessageCache.getLatestCachedPreview('conv-unknown'), isNull);
    });
  });

  group('MessageCacheException', () {
    test('toString includes message', () {
      final ex = MessageCacheException('test error');
      expect(ex.toString(), 'MessageCacheException: test error');
      expect(ex.message, 'test error');
    });
  });
}
