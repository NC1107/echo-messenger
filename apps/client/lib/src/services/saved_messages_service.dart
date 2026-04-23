import 'package:hive_flutter/hive_flutter.dart';

import '../models/chat_message.dart';
import '../utils/debug_log.dart';

/// Local bookmark store backed by a Hive box.
///
/// Each saved message is stored under its [ChatMessage.id] key as a plain JSON
/// map (same schema as [ChatMessage.toJson]). The service is a singleton so
/// all callers share the same open box.
class SavedMessagesService {
  SavedMessagesService._();

  static final SavedMessagesService instance = SavedMessagesService._();

  static const _boxName = 'echo_saved_messages';

  Box<Map>? _box;

  /// Open the Hive box. Call once during app init (after [Hive.initFlutter]).
  Future<void> init() async {
    try {
      _box = await Hive.openBox<Map>(_boxName);
    } catch (e) {
      debugLog('Failed to open saved-messages box: $e', 'SavedMessagesService');
    }
  }

  /// Save [msg] to local bookmarks. Idempotent if already saved.
  Future<void> saveMessage(ChatMessage msg) async {
    final box = _box;
    if (box == null) return;
    try {
      await box.put(msg.id, msg.toJson());
    } catch (e) {
      debugLog('saveMessage error: $e', 'SavedMessagesService');
    }
  }

  /// Remove the message with [messageId] from local bookmarks.
  Future<void> unsaveMessage(String messageId) async {
    final box = _box;
    if (box == null) return;
    try {
      await box.delete(messageId);
    } catch (e) {
      debugLog('unsaveMessage error: $e', 'SavedMessagesService');
    }
  }

  /// Return all saved messages sorted newest-first by timestamp.
  List<SavedMessage> getSavedMessages() {
    final box = _box;
    if (box == null) return [];
    final result = <SavedMessage>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      try {
        final json = Map<String, dynamic>.from(raw);
        final msg = ChatMessage.fromServerJson(json, '');
        final savedAt =
            DateTime.tryParse(raw['saved_at'] as String? ?? '') ??
            DateTime.now();
        result.add(SavedMessage(message: msg, savedAt: savedAt));
      } catch (_) {
        // Skip corrupt entries.
      }
    }
    result.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return result;
  }

  /// Whether [messageId] is currently bookmarked.
  bool isMessageSaved(String messageId) {
    return _box?.containsKey(messageId) ?? false;
  }

  /// Persist a [ChatMessage] enriched with the current wall-clock time.
  Future<void> _saveWithTimestamp(ChatMessage msg) async {
    final box = _box;
    if (box == null) return;
    try {
      final json = msg.toJson()
        ..['saved_at'] = DateTime.now().toIso8601String();
      await box.put(msg.id, json);
    } catch (e) {
      debugLog('_saveWithTimestamp error: $e', 'SavedMessagesService');
    }
  }

  /// Public entry-point that stores a message with its bookmark timestamp.
  Future<void> bookmark(ChatMessage msg) => _saveWithTimestamp(msg);
}

/// A [ChatMessage] paired with the time it was bookmarked.
class SavedMessage {
  final ChatMessage message;
  final DateTime savedAt;

  const SavedMessage({required this.message, required this.savedAt});
}
