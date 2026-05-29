/// Web-only debug-mode test probe that exposes minimal canvas state to
/// `window.__echoTestProbe__` so e2e specs can verify committed stroke counts
/// and active-stroke metadata without poking at Riverpod internals.
///
/// Active only when [kIsWeb] is true and kReleaseMode is false. The exported
/// object is read-only (no setters); all canvas interaction is driven through
/// real touch/gesture events. The lounge screen registers its canvas provider
/// on mount and unregisters on dispose.
///
/// Cited from: tests/e2e/output/mobile-audit-report.md (Known gaps section).
library;

// This file contains a conditional export: the real web implementation
// (web_test_probe_web.dart) is loaded on web targets and a no-op stub
// (web_test_probe_stub.dart) on non-web targets.  Both expose the same
// public interface so callers never need an `if (kIsWeb)` guard.
export 'web_test_probe_stub.dart'
    if (dart.library.html) 'web_test_probe_web.dart';
