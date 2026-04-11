import 'package:hive_flutter/hive_flutter.dart';

import '../models/chat_message.dart';

class MessageCache {
  static const _boxName = 'echo_messages';
  static Box<Map>? _box;

  static Future<void> init() async {
    _box = await Hive.openBox<Map>(_boxName);
  }

  /// Re-initialize with a user-scoped Hive box.
  /// Call after login to isolate message cache per user.
  static Future<void> initForUser(String userId, String serverHost) async {
    if (_box != null && _box!.isOpen) await _box!.close();
    final sanitized = '${userId}_$serverHost'.replaceAll(RegExp(r'[^\w]'), '_');
    _box = await Hive.openBox<Map>('echo_messages_$sanitized');
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

  /// Look up a single cached message by conversation and message ID.
  ///
  /// Returns null if the message is not in the cache.  Used by the history
  /// decryption path to avoid re-decrypting messages that were already
  /// decrypted and cached (Double Ratchet keys are consumed once and cannot
  /// be re-derived).
  static ChatMessage? getCachedMessage(
    String conversationId,
    String messageId,
    String myUserId,
  ) {
    final box = _box;
    if (box == null) return null;
    final raw = box.get('$conversationId:$messageId');
    if (raw == null) return null;
    final json = Map<String, dynamic>.from(raw);
    return ChatMessage.fromServerJson(json, myUserId);
  }

  static Future<void> clearAll() async {
    await _box?.clear();
  }

  /// Number of cached message entries (conversations × messages).
  static int entryCount() => _box?.length ?? 0;
}
