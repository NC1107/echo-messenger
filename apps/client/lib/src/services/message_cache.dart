import 'package:hive_flutter/hive_flutter.dart';

import '../models/chat_message.dart';
import '../utils/debug_log.dart';
import 'secure_key_store.dart';

/// Per-conversation Hive message cache.
///
/// One Hive box is opened lazily per conversation:
///   echo_msg_userScope_c_convId
///
/// This keeps reads O(messages_in_conv) instead of O(total_messages). The
/// old single-box layout (echo_messages_scope) is dropped on the first
/// initForUser call because the cache is a performance optimisation, not a
/// source of truth -- messages reload from the server automatically.
class MessageCache {
  /// Current user-scoped prefix, e.g. echo_msg_user1_example_com.
  static String? _userPrefix;

  /// Open per-conversation boxes, keyed by conversationId.
  static final Map<String, Box<Map>> _convBoxes = {};

  /// Encryption key bytes for the current session, or null for no encryption.
  static List<int>? _encKeyBytes;

  /// Maximum messages kept per conversation. Oldest entries are evicted when
  /// the limit is exceeded to bound box size.
  static const int _maxPerConv = 500;

  /// Compaction: compact a conversation box after 50 deleted entries.
  static CompactionStrategy get _compactionStrategy =>
      (entries, deletedEntries) => deletedEntries > 50;

  /// Strings that represent decryption failures. These must never be cached
  /// because doing so permanently replaces the real ciphertext and blocks
  /// future decrypt retries. Also used by [ConversationsNotifier] to reject
  /// failure strings from being stored as conversation previews (#664).
  static const List<String> failureSentinels = [
    '[Message encrypted - history unavailable]',
    '[Encrypted history]',
    '[Could not decrypt - encryption keys may be out of sync]',
  ];

  static Future<void> init() async {
    // Pre-fetch the encryption key so it is ready for _openBox calls.
    _encKeyBytes = await _getEncryptionKey();
  }

  /// Re-initialize with a user-scoped prefix.
  /// Call after login to isolate message cache per user.
  ///
  /// Idempotent: returns immediately if the target prefix is already active.
  /// Closes previously-open per-conv boxes and drops the legacy single-box
  /// (echo_messages_scope) -- the cache is regenerable from the server.
  static Future<void> initForUser(String userId, String serverHost) async {
    final sanitized = '${userId}_$serverHost'.replaceAll(RegExp(r'[^\w]'), '_');
    final newPrefix = 'echo_msg_$sanitized';

    if (_userPrefix == newPrefix) return; // already active

    await _closeAllConvBoxes();
    _userPrefix = newPrefix;
    _encKeyBytes ??= await _getEncryptionKey();

    // Drop the legacy single-box so old-format files do not linger on disk.
    try {
      await Hive.deleteBoxFromDisk('echo_messages_$sanitized');
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  static Future<void> cacheMessages(
    String conversationId,
    List<ChatMessage> messages,
  ) async {
    final box = await _boxForConv(conversationId);
    if (box == null) return;
    final entries = <String, Map<dynamic, dynamic>>{};
    for (final msg in messages) {
      if (msg.id.startsWith('pending_')) continue;
      if (failureSentinels.contains(msg.content)) continue;
      entries[msg.id] = msg.toJson();
    }
    if (entries.isEmpty) return;
    await box.putAll(entries);
    // Evict oldest entries when the box exceeds _maxPerConv.
    if (box.length > _maxPerConv) {
      final excess = box.length - _maxPerConv;
      final keysToDelete = box.keys.take(excess).toList();
      await box.deleteAll(keysToDelete);
    }
  }

  static Future<List<ChatMessage>> getCachedMessages(
    String conversationId,
    String myUserId,
  ) async {
    final box = await _boxForConv(conversationId);
    if (box == null) return [];
    final messages = <ChatMessage>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw != null) {
        final json = Map<String, dynamic>.from(raw);
        messages.add(ChatMessage.fromServerJson(json, myUserId));
      }
    }
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }

  /// Look up a single cached message by conversation and message ID.
  ///
  /// Returns null if the message is not in the cache. Used by the history
  /// decryption path to avoid re-decrypting messages that were already
  /// decrypted and cached (Double Ratchet keys are consumed once and cannot
  /// be re-derived).
  static Future<ChatMessage?> getCachedMessage(
    String conversationId,
    String messageId,
    String myUserId,
  ) async {
    final box = await _boxForConv(conversationId);
    if (box == null) return null;
    final raw = box.get(messageId);
    if (raw == null) return null;
    final json = Map<String, dynamic>.from(raw);
    return ChatMessage.fromServerJson(json, myUserId);
  }

  /// Return the most recent cached [ChatMessage] for a conversation, or null.
  ///
  /// Used by [ChatNotifier.hydrateStatusFromCache] to populate the in-memory
  /// status map on cold start before any WS read_receipt events arrive (#573).
  static Future<ChatMessage?> getLatestCachedMessage(
    String conversationId,
    String myUserId,
  ) async {
    final box = await _boxForConv(conversationId);
    if (box == null) return null;
    String? latestTimestamp;
    ChatMessage? latestMsg;
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      final json = Map<String, dynamic>.from(raw);
      final ts =
          json['created_at'] as String? ?? json['timestamp'] as String? ?? '';
      if (latestTimestamp == null || ts.compareTo(latestTimestamp) > 0) {
        latestTimestamp = ts;
        latestMsg = ChatMessage.fromServerJson(json, myUserId);
      }
    }
    return latestMsg;
  }

  /// Return the content of the most recent cached message for a conversation.
  /// Used by loadConversations() to show decrypted previews for messages that
  /// were decrypted in a previous session and stored in the Hive cache.
  static Future<String?> getLatestCachedPreview(String conversationId) async {
    final box = await _boxForConv(conversationId);
    if (box == null) return null;
    String? latest;
    String? latestTimestamp;
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      final json = Map<String, dynamic>.from(raw);
      final ts =
          json['created_at'] as String? ?? json['timestamp'] as String? ?? '';
      if (latestTimestamp == null || ts.compareTo(latestTimestamp) > 0) {
        latestTimestamp = ts;
        final content = json['content'] as String?;
        // Skip failure sentinels written before the guard was introduced;
        // they must not surface as conversation previews (#664).
        latest = (content != null && failureSentinels.contains(content))
            ? null
            : content;
      }
    }
    return latest;
  }

  /// Remove a single message from the cache.
  static Future<void> removeMessage(
    String conversationId,
    String messageId,
  ) async {
    final box = await _boxForConv(conversationId);
    await box?.delete(messageId);
  }

  static Future<void> clearAll() async {
    final names = _convBoxes.keys.map((c) => _boxName(c)).toList();
    await _closeAllConvBoxes();
    for (final name in names) {
      try {
        await Hive.deleteBoxFromDisk(name);
      } catch (_) {}
    }
  }

  /// Delete all on-disk Hive boxes for a (user, server) pair. Used by the
  /// 'Forget server' flow in settings. Idempotent: missing boxes are a no-op.
  static Future<void> dropForServer(String userId, String serverHost) async {
    final sanitized = '${userId}_$serverHost'.replaceAll(RegExp(r'[^\w]'), '_');
    final prefix = 'echo_msg_$sanitized';
    if (_userPrefix == prefix) {
      final toClose = _convBoxes.keys.toList();
      for (final convId in toClose) {
        final box = _convBoxes.remove(convId);
        try {
          await box?.close();
        } catch (_) {}
        try {
          await Hive.deleteBoxFromDisk(_boxNameFor(prefix, convId));
        } catch (_) {}
      }
      _userPrefix = null;
    }
    try {
      await Hive.deleteBoxFromDisk('echo_messages_$sanitized');
    } catch (_) {}
  }

  /// Total number of cached message entries across all open conv boxes.
  static int entryCount() =>
      _convBoxes.values.fold(0, (sum, box) => sum + box.length);

  /// IDs of all conversations that have an open cache box in this session.
  /// Used by [ExportService] to iterate over cached data.
  static List<String> get openConversationIds =>
      List<String>.unmodifiable(_convBoxes.keys);

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static String _boxName(String conversationId) =>
      _boxNameFor(_userPrefix ?? 'echo_msg_default', conversationId);

  static String _boxNameFor(String prefix, String conversationId) {
    final safeConv = conversationId.replaceAll(RegExp(r'[^\w]'), '_');
    return '${prefix}_c_$safeConv';
  }

  /// Return the box for [conversationId], opening it lazily if necessary.
  static Future<Box<Map>?> _boxForConv(String conversationId) async {
    final existing = _convBoxes[conversationId];
    if (existing != null && existing.isOpen) return existing;
    if (_userPrefix == null) return null;
    try {
      final box = await _openBox(_boxName(conversationId));
      _convBoxes[conversationId] = box;
      return box;
    } catch (e) {
      debugLog(
        'MessageCache: failed to open box for $conversationId: $e',
        'MessageCache',
      );
      return null;
    }
  }

  static Future<void> _closeAllConvBoxes() async {
    for (final box in _convBoxes.values) {
      try {
        await box.close();
      } catch (_) {}
    }
    _convBoxes.clear();
  }

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

  /// Open a Hive box (encrypted if a key is available, plain otherwise).
  static Future<Box<Map>> _openBox(String name) async {
    final keyBytes = _encKeyBytes;
    if (keyBytes != null) {
      return _openEncryptedBox(name, keyBytes);
    }
    return Hive.openBox<Map>(name, compactionStrategy: _compactionStrategy);
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
      return await Hive.openBox<Map>(
        name,
        encryptionCipher: cipher,
        compactionStrategy: _compactionStrategy,
      );
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
      return await Hive.openBox<Map>(
        name,
        encryptionCipher: cipher,
        compactionStrategy: _compactionStrategy,
      );
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
