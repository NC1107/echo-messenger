import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'encrypted_preview_provider.g.dart';

/// SharedPreferences key for the "show encrypted previews" setting.
const kShowEncryptedPreviewsKey = 'show_encrypted_previews';

/// Controls whether the sidebar conversation list and notification bodies
/// show decrypted plaintext previews (true, default) or always render
/// `[Encrypted]` for end-to-end encrypted messages (false).
///
/// Modelled on [GifPlayback] — a simple bool backed by SharedPreferences.
@Riverpod(keepAlive: true)
class ShowEncryptedPreviews extends _$ShowEncryptedPreviews {
  @override
  bool build() {
    _load();
    return true; // default ON — preserves current behavior
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(kShowEncryptedPreviewsKey) ?? true;
  }

  /// Persist + apply a new preference value.
  Future<void> setValue(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kShowEncryptedPreviewsKey, value);
  }
}
