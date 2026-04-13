import 'package:hive_flutter/hive_flutter.dart';

import '../models/chat_message.dart';
import '../utils/debug_log.dart';
import 'secure_key_store.dart';

class MessageCache {
  static const _boxName = 'echo_messages';
  static Box<Map>? _box;

  /// Name of the currently-open Hive box, used to make [initForUser]
  /// idempotent (skip close/reopen when the target box is already active).
  static String? _currentBoxName;

  /// Strings that represent decryption failures. These must never be cached
  /// because doing so permanently replaces the real ciphertext and blocks
  /// future decrypt retries.
  static const List<String> _failureSentinels = [
    '[Message encrypted - history unavailable]',
    '[Encrypted history]',
    '[Could not decrypt - encryption keys may be out of sync]',
  ];

  static Future<void> init() async {
    final keyBytes = await _getEncryptionKey();
    if (keyBytes != null) {
      _box = await _openEncryptedBox(_boxName, keyBytes);
    } else {
      // Encryption key unavailable (e.g. secure storage not ready pre-login).
      // Fall back to unencrypted so the app can still start.
      _box = await Hive.openBox<Map>(_boxName);
    }
    _currentBoxName = _boxName;
  }

  /// Re-initialize with a user-scoped Hive box.
  /// Call after login to isolate message cache per user.
  ///
  /// Idempotent: returns immediately if the target box is already open.
  /// Retries up to 3 times on failure (web IndexedDB can be flaky during
  /// page refresh). Falls back to the generic shared box on total failure
  /// so the session can still cache newly-decrypted messages, then throws
  /// [MessageCacheException] to let the caller log the issue.
  static Future<void> initForUser(String userId, String serverHost) async {
    final sanitized = '${userId}_$serverHost'.replaceAll(RegExp(r'[^\w]'), '_');
    final targetName = 'echo_messages_$sanitized';

    // Already open on the correct box -- nothing to do.
    if (_currentBoxName == targetName && _box?.isOpen == true) return;

    // Close the previous box if it is open and belongs to a different user.
    if (_box != null && _box!.isOpen && _currentBoxName != targetName) {
      try {
        await _box!.close();
      } catch (_) {
        // Close failures on web are non-fatal; the new open will handle it.
      }
    }

    final keyBytes = await _getEncryptionKey();

    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (keyBytes != null) {
          _box = await _openEncryptedBox(targetName, keyBytes);
        } else {
          _box = await Hive.openBox<Map>(targetName);
        }
        _currentBoxName = targetName;
        return;
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
      }
    }

    // All attempts failed -- fall back to generic box so this session can
    // still cache newly-decrypted messages. Historical cache may be
    // unavailable.
    try {
      if (keyBytes != null) {
        _box = await _openEncryptedBox(_boxName, keyBytes);
      } else {
        _box = await Hive.openBox<Map>(_boxName);
      }
      _currentBoxName = _boxName;
    } catch (_) {
      _box = null;
      _currentBoxName = null;
    }
    throw MessageCacheException(
      'Failed to open user-scoped Hive box after 3 attempts: $lastError',
    );
  }

  static Future<void> cacheMessages(
    String conversationId,
    List<ChatMessage> messages,
  ) async {
    final box = _box;
    if (box == null) return;
    for (final msg in messages) {
      if (msg.id.startsWith('pending_')) continue;
      // Skip failure sentinels -- caching these would permanently replace the
      // real ciphertext and block future retries.
      if (_failureSentinels.contains(msg.content)) continue;
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

  /// Return the content of the most recent cached message for a conversation.
  /// Used by loadConversations() to show decrypted previews for messages that
  /// were decrypted in a previous session and stored in the Hive cache.
  static String? getLatestCachedPreview(String conversationId) {
    final box = _box;
    if (box == null) return null;
    String? latest;
    String? latestTimestamp;
    for (final key in box.keys) {
      if (!(key as String).startsWith('$conversationId:')) continue;
      final raw = box.get(key);
      if (raw == null) continue;
      final json = Map<String, dynamic>.from(raw);
      final ts =
          json['created_at'] as String? ?? json['timestamp'] as String? ?? '';
      if (latestTimestamp == null || ts.compareTo(latestTimestamp) > 0) {
        latestTimestamp = ts;
        latest = json['content'] as String?;
      }
    }
    return latest;
  }

  static Future<void> clearAll() async {
    await _box?.clear();
  }

  /// Number of cached message entries (conversations x messages).
  static int entryCount() => _box?.length ?? 0;

  /// Retrieve the Hive encryption key from secure storage, or null if
  /// secure storage is not available yet (e.g. before first login).
  static Future<List<int>?> _getEncryptionKey() async {
    try {
      return await SecureKeyStore.instance.getOrCreateHiveCacheKey();
    } catch (e) {
      debugLog('Failed to get Hive encryption key: $e', 'MessageCache');
      return null;
    }
  }

  /// Open a Hive box with AES encryption. If the box was previously stored
  /// unencrypted (or with a different key), the open will fail with a cipher
  /// mismatch. In that case, delete the old box and recreate it -- the cache
  /// is a performance optimisation, not a source of truth.
  static Future<Box<Map>> _openEncryptedBox(
    String name,
    List<int> keyBytes,
  ) async {
    final cipher = HiveAesCipher(keyBytes);
    try {
      return await Hive.openBox<Map>(name, encryptionCipher: cipher);
    } catch (e) {
      // Cipher mismatch with an existing unencrypted box -- delete and retry.
      debugLog(
        'Encrypted open failed for $name, deleting stale box: $e',
        'MessageCache',
      );
      try {
        await Hive.deleteBoxFromDisk(name);
      } catch (_) {
        // Best-effort deletion; openBox below will overwrite anyway.
      }
      return await Hive.openBox<Map>(name, encryptionCipher: cipher);
    }
  }
}

/// Exception thrown when [MessageCache.initForUser] fails to open the
/// user-scoped Hive box after all retry attempts.
class MessageCacheException implements Exception {
  final String message;

  MessageCacheException(this.message);

  @override
  String toString() => 'MessageCacheException: $message';
}
