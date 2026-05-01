import 'dart:io';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/services/export_service.dart';
import 'package:echo_app/src/services/message_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

ChatMessage _msg({
  required String id,
  String conversationId = 'conv-1',
  String content = 'hello',
  String fromUserId = 'user-1',
  String fromUsername = 'alice',
  String timestamp = '2025-01-01T10:00:00Z',
}) {
  return ChatMessage(
    id: id,
    fromUserId: fromUserId,
    fromUsername: fromUsername,
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
    tempDir = await Directory.systemTemp.createTemp('export_service_test_');
    Hive.init(tempDir.path);
    await MessageCache.init();
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    await MessageCache.clearAll();
  });

  group('ExportService.buildExportPayload', () {
    test('top-level shape has required keys', () async {
      await MessageCache.initForUser('user-1', 'example.com');
      await MessageCache.cacheMessages('conv-1', [_msg(id: 'm1')]);

      final payload = await ExportService.buildExportPayload(
        userId: 'user-1',
        username: 'alice',
      );

      expect(payload['version'], 1);
      expect(payload['user_id'], 'user-1');
      expect(payload['username'], 'alice');
      expect(payload.containsKey('exported_at'), isTrue);
      expect(payload['conversations'], isA<List>());
    });

    test('messages are grouped by conversation', () async {
      await MessageCache.initForUser('user-1', 'example.com');
      await MessageCache.cacheMessages('conv-a', [
        _msg(id: 'a1', conversationId: 'conv-a', content: 'hello'),
        _msg(id: 'a2', conversationId: 'conv-a', content: 'world'),
      ]);
      await MessageCache.cacheMessages('conv-b', [
        _msg(id: 'b1', conversationId: 'conv-b', content: 'other'),
      ]);

      final payload = await ExportService.buildExportPayload(
        userId: 'user-1',
        username: 'alice',
        conversationNames: {'conv-a': 'Alice & Bob', 'conv-b': 'Group chat'},
      );

      final convs = payload['conversations'] as List;
      expect(convs.length, greaterThanOrEqualTo(2));

      final convA =
          convs.firstWhere((c) => (c as Map)['conversation_id'] == 'conv-a')
              as Map;
      expect(convA['name'], 'Alice & Bob');
      final msgs = convA['messages'] as List;
      expect(msgs.length, 2);
      expect(msgs.map((m) => (m as Map)['id']), containsAll(['a1', 'a2']));
    });

    test('each message has expected fields', () async {
      await MessageCache.initForUser('user-1', 'example.com');
      await MessageCache.cacheMessages('conv-1', [
        _msg(id: 'msg-1', content: 'hi there', fromUserId: 'u1'),
      ]);

      final payload = await ExportService.buildExportPayload(
        userId: 'user-1',
        username: 'alice',
      );

      final convs = payload['conversations'] as List;
      final conv =
          convs.firstWhere((c) => (c as Map)['conversation_id'] == 'conv-1')
              as Map;
      final msg = (conv['messages'] as List).first as Map;

      expect(msg['id'], 'msg-1');
      expect(msg['content'], 'hi there');
      expect(msg['sender_id'], 'u1');
      expect(msg['sender_username'], 'alice');
      expect(msg.containsKey('created_at'), isTrue);
      // Private/sensitive keys must be absent.
      expect(msg.containsKey('is_encrypted'), isFalse);
    });

    test('failure sentinels are excluded from the export', () async {
      await MessageCache.initForUser('user-1', 'example.com');
      final bad = _msg(
        id: 'sentinel-msg',
        content: MessageCache.failureSentinels.first,
      );
      final good = _msg(id: 'good-msg', content: 'real message');
      // Cache only the good message -- sentinels are blocked at cache write.
      // Simulate a sentinel reaching buildExportPayload by caching a good
      // message then verifying sentinels would be filtered at export time.
      await MessageCache.cacheMessages('conv-1', [good, bad]);

      final payload = await ExportService.buildExportPayload(
        userId: 'user-1',
        username: 'alice',
      );

      final convs = payload['conversations'] as List;
      final conv =
          convs.firstWhere((c) => (c as Map)['conversation_id'] == 'conv-1')
              as Map;
      final msgContents = (conv['messages'] as List)
          .map((m) => (m as Map)['content'] as String)
          .toList();

      expect(msgContents, contains('real message'));
      expect(msgContents, isNot(contains(MessageCache.failureSentinels.first)));
    });

    test('empty cache produces zero-length conversations list', () async {
      await MessageCache.initForUser('user-empty', 'example.com');
      // No messages cached.
      final payload = await ExportService.buildExportPayload(
        userId: 'user-empty',
        username: 'nobody',
      );

      final convs = payload['conversations'] as List;
      expect(convs, isEmpty);
    });
  });
}
