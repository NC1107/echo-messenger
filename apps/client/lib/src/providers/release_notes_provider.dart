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

    // Fresh install bootstrap: if we have no record of a previously-
    // shown version, mark the CURRENT app version as seen and bail
    // out.  The user gets release notes only on FUTURE updates, never
    // on first launch (matches Discord / VS Code / GitHub Desktop UX).
    final stored = prefs.getString(_lastShownVersionKey);
    if (stored == null) {
      if (appVersion != 'dev') {
        await prefs.setString(_lastShownVersionKey, appVersion);
      }
      return null;
    }

    // Already shown the notes for this version — done.
    if (stored == appVersion) return null;

    // We have an outdated "last shown" record; the user updated since
    // we last showed them notes.  Watch updateProvider for the body to
    // arrive.  If updateProvider's check completed before this notifier
    // built, ref.read returns the populated state immediately.
    final update = ref.watch(updateProvider);
    final body = update.releaseBody;
    final remote = update.latestVersion;

    // Two cases for the version comparison:
    //   1. updateProvider already saw the new release ⇒ remote == appVersion
    //   2. server lags ⇒ remote is older than appVersion (still show
    //      whatever notes were cached for the version we know about,
    //      since the user has clearly updated past `stored`).
    // Either way, we render the cached body if non-empty.
    if (body == null || body.isEmpty) return null;

    // Show notes for the running app version.  The body in cache may
    // correspond to a slightly different release on the server, but
    // for the user the headline is "you updated; here's what changed".
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
