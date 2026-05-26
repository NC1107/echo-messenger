import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../version.dart';
import 'update_provider.dart';

/// Persisted key: the app version whose release notes the user has
/// already been shown.  Set to `appVersion` on fresh install so first
/// launches don't surface a "What's New" modal that assumes prior
/// knowledge.
const String _lastShownVersionKey = 'release_notes_last_shown';

/// Snapshot of what the What's-New modal should render.  `null` when
/// either the release-notes fetch hasn't completed or the user has
/// already seen the current version's notes.
class ReleaseNotesView {
  /// Version string the body belongs to (e.g. "0.0.302").
  final String version;

  /// Cleaned markdown body (auto-generated footer + Dependabot URLs
  /// stripped by [sanitizeReleaseBody]).
  final String body;

  const ReleaseNotesView({required this.version, required this.body});
}

/// Riverpod provider exposing whether the What's-New modal should be
/// shown on the current launch.  Computed from [updateProvider]'s
/// cached release body + a persisted "last shown" version key.
///
/// Returns null until both the update check has run AND the persisted
/// "last shown" key has been read — guards against flashing the modal
/// before the first-install bootstrap completes.
final releaseNotesProvider =
    AsyncNotifierProvider<ReleaseNotesNotifier, ReleaseNotesView?>(
      ReleaseNotesNotifier.new,
    );

class ReleaseNotesNotifier extends AsyncNotifier<ReleaseNotesView?> {
  @override
  Future<ReleaseNotesView?> build() async {
    final prefs = await SharedPreferences.getInstance();

    // Fresh install: mark current version seen; notes only on future updates.
    final stored = prefs.getString(_lastShownVersionKey);
    if (stored == null) {
      if (appVersion != 'dev') {
        await prefs.setString(_lastShownVersionKey, appVersion);
      }
      return null;
    }

    // Already shown the notes for this version — done.
    if (stored == appVersion) return null;

    // Outdated last-shown: user updated since; watch updateProvider for body.
    final update = ref.watch(updateProvider);
    final body = update.releaseBody;
    final remote = update.latestVersion;

    // Render whatever body the cache holds — server may lag but user updated.
    if (body == null || body.isEmpty) return null;
    return ReleaseNotesView(version: remote ?? appVersion, body: body);
  }

  /// Persist that the user has seen the notes for the current app
  /// version, and clear the in-memory `state` so the modal doesn't
  /// re-fire on hot reload.
  Future<void> markShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastShownVersionKey, appVersion);
    state = const AsyncData(null);
  }

  /// Test-only override: reset the persisted "last shown" key so unit
  /// tests can re-exercise the bootstrap path without restarting the
  /// process.
  Future<void> resetForTesting() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastShownVersionKey);
    state = const AsyncData(null);
  }
}
