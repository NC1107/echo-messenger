import 'dart:io';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/services/saved_messages_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Build a minimal [ChatMessage] for testing.
ChatMessage _msg({
  required String id,
  String conversationId = 'conv-1',
  String content = 'hello',
  String fromUserId = 'sender-1',
  bool isMine = false,
}) {
  return ChatMessage(
    id: id,
    fromUserId: fromUserId,
    fromUsername: 'alice',
    conversationId: conversationId,
    content: content,
    timestamp: '2026-01-01T10:00:00Z',
    isMine: isMine,
  );
}

void main() {
  late Directory tempDir;
  late SavedMessagesService svc;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('saved_msg_test_');
    Hive.init(tempDir.path);
  });

  setUp(() async {
    // Re-open the service for each test so boxes start clean.
    svc = SavedMessagesService.instance;
    await svc.init();
  });

  tearDown(() async {
    // Close and delete all Hive boxes between tests.
    await Hive.deleteBoxFromDisk('echo_saved_messages');
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  // ---------------------------------------------------------------------------
  // bookmark / isMessageSaved
  // ---------------------------------------------------------------------------

  group('SavedMessagesService.bookmark', () {
    test('bookmarked message is detected by isMessageSaved', () async {
      final msg = _msg(id: 'msg-1');
      await svc.bookmark(msg);

      expect(svc.isMessageSaved('msg-1'), isTrue);
    });

    test('unknown message id returns false from isMessageSaved', () {
      expect(svc.isMessageSaved('does-not-exist'), isFalse);
    });

    test(
      'bookmarking is idempotent -- double save does not duplicate',
      () async {
        final msg = _msg(id: 'msg-2');
        await svc.bookmark(msg);
        await svc.bookmark(msg);

        final saved = svc.getSavedMessages();
        expect(saved.where((s) => s.message.id == 'msg-2'), hasLength(1));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // unsaveMessage
  // ---------------------------------------------------------------------------

  group('SavedMessagesService.unsaveMessage', () {
    test('removes a previously bookmarked message', () async {
      final msg = _msg(id: 'msg-3');
      await svc.bookmark(msg);
      await svc.unsaveMessage('msg-3');

      expect(svc.isMessageSaved('msg-3'), isFalse);
    });

    test('unsaving an unknown id is a no-op (does not throw)', () async {
      // Should complete without throwing.
      await svc.unsaveMessage('nonexistent');
    });
  });

  // ---------------------------------------------------------------------------
  // getSavedMessages
  // ---------------------------------------------------------------------------

  group('SavedMessagesService.getSavedMessages', () {
    test('returns empty list when nothing is bookmarked', () {
      expect(svc.getSavedMessages(), isEmpty);
    });

    test('returns all bookmarked messages', () async {
      await svc.bookmark(_msg(id: 'a'));
      await svc.bookmark(_msg(id: 'b'));

      expect(svc.getSavedMessages(), hasLength(2));
    });

    test('returns messages sorted newest-first', () async {
      await svc.bookmark(_msg(id: 'first'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await svc.bookmark(_msg(id: 'second'));

      final saved = svc.getSavedMessages();
      expect(saved.first.message.id, 'second');
      expect(saved.last.message.id, 'first');
    });

    test('returned SavedMessage has non-null savedAt timestamp', () async {
      final before = DateTime.now();
      await svc.bookmark(_msg(id: 'ts-check'));
      final after = DateTime.now();

      final saved = svc.getSavedMessages().first;
      expect(
        saved.savedAt.isAfter(before.subtract(const Duration(seconds: 1))),
        isTrue,
      );
      expect(
        saved.savedAt.isBefore(after.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('message content is preserved through bookmark roundtrip', () async {
      final msg = _msg(id: 'content-test', content: 'Hello, world!');
      await svc.bookmark(msg);

      final saved = svc.getSavedMessages().first;
      expect(saved.message.content, 'Hello, world!');
    });

    test('returns empty list after all messages are unsaved', () async {
      await svc.bookmark(_msg(id: 'x'));
      await svc.bookmark(_msg(id: 'y'));
      await svc.unsaveMessage('x');
      await svc.unsaveMessage('y');

      expect(svc.getSavedMessages(), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // SavedMessage data class
  // ---------------------------------------------------------------------------

  group('SavedMessage', () {
    test('stores message and savedAt', () {
      final msg = _msg(id: 'sm-1');
      final now = DateTime.now();
      final saved = SavedMessage(message: msg, savedAt: now);

      expect(saved.message.id, 'sm-1');
      expect(saved.savedAt, now);
    });
  });
}
