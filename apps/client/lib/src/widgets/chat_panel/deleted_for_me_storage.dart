import 'package:shared_preferences/shared_preferences.dart';

/// Persistent blocklist of message IDs deleted via "delete for me".
/// Survives app restarts so messages don't reappear on history reload.
/// Process-wide singleton: every `_ChatPanelState` instance shares one set.
class DeletedForMeStorage {
  DeletedForMeStorage._();

  static const _key = 'deleted_for_me_ids';
  static Set<String> ids = {};
  static bool _loaded = false;

  /// Lazy-load the persisted set on first read. Cheap to call repeatedly.
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    ids = (prefs.getStringList(_key) ?? []).toSet();
  }

  /// Add [messageId] to the set and persist.
  static Future<void> add(String messageId) async {
    ids.add(messageId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, ids.toList());
  }
}

/// Persistent set of conversation IDs the user dismissed the encryption
/// banner on. Mirrors [DeletedForMeStorage] semantics.
class DismissedBannersStorage {
  DismissedBannersStorage._();

  static const _key = 'dismissed_encryption_banners';
  static Set<String> ids = {};
  static bool _loaded = false;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    ids = (prefs.getStringList(_key) ?? []).toSet();
  }

  static Future<void> add(String conversationId) async {
    ids.add(conversationId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, ids.toList());
  }
}
