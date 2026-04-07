import 'package:hive_flutter/hive_flutter.dart';

import '../models/chat_message.dart';

class MessageCache {
  static const _boxName = 'echo_messages';
  static Box<Map>? _box;

  static Future<void> init() async {
    _box = await Hive.openBox<Map>(_boxName);
  }

  static Future<void> cacheMessages(
    String conversationId,
    List<ChatMessage> messages,
  ) async {
    final box = _box;
    if (box == null) return;
    for (final msg in messages) {
      if (msg.id.startsWith('pending_')) continue;
      await box.put('$conversationId:${msg.id}', msg.toJson());
    }
  }

  static List<ChatMessage> getCachedMessages(
    String conversationId,
    String myUserId,
  ) {
    final box = _box;
    if (box == null) return [];
    final messages = <ChatMessage>[];
    for (final key in box.keys) {
      if ((key as String).startsWith('$conversationId:')) {
        final raw = box.get(key);
        if (raw != null) {
          final json = Map<String, dynamic>.from(raw);
          messages.add(ChatMessage.fromServerJson(json, myUserId));
        }
      }
    }
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }

  static Future<void> clearAll() async {
    await _box?.clear();
  }
}
