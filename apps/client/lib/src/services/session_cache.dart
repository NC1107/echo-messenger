/// LRU + TTL cache for Signal Protocol session state with secure zeroing.
///
/// Forward-secrecy hardening (#343): sessions are evicted from RAM after a
/// configurable idle TTL or when the cache exceeds [SessionCache.maxEntries].
/// Evicted session key material (root key, chain keys, skipped message keys)
/// is explicitly zeroed before the entry is dropped.
///
/// On cache miss the caller is expected to reload the session from persistent
/// storage (`SecureKeyStore`) -- eviction is non-destructive to the on-disk
/// state.
library;

import 'dart:async';
import 'dart:collection';

import 'signal_session.dart';

/// LRU + TTL cache for [SignalSession] instances.
class SessionCache {
  /// Default idle TTL: 24 hours.
  static const Duration defaultTtl = Duration(hours: 24);

  /// Default LRU cap: 200 sessions.
  static const int defaultMaxEntries = 200;

  /// Default sweep interval: 15 minutes.
  static const Duration defaultSweepInterval = Duration(minutes: 15);

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _now;
  final Duration _sweepInterval;
  final bool _enablePeriodicEviction;
  final LinkedHashMap<String, _Entry> _entries = LinkedHashMap();
  Timer? _sweepTimer;

  SessionCache({
    this.ttl = defaultTtl,
    this.maxEntries = defaultMaxEntries,
    DateTime Function()? clock,
    bool enablePeriodicEviction = true,
    Duration sweepInterval = defaultSweepInterval,
  }) : _now = clock ?? DateTime.now,
       _sweepInterval = sweepInterval,
       _enablePeriodicEviction = enablePeriodicEviction;

  /// Lazily start the periodic sweep on first insertion. Avoids leaking
  /// timers in widget tests that construct a [CryptoService] but never
  /// populate the cache.
  void _ensureSweepTimer() {
    if (!_enablePeriodicEviction || _sweepTimer != null) return;
    _sweepTimer = Timer.periodic(_sweepInterval, (_) {
      evictExpired();
      // Stop the timer when the cache empties so we don't leak in tests.
      if (_entries.isEmpty) {
        _sweepTimer?.cancel();
        _sweepTimer = null;
      }
    });
  }

  /// Number of cached entries.
  int get length => _entries.length;

  /// True when no entries are cached.
  bool get isEmpty => _entries.isEmpty;

  /// Returns the cached session if present and not expired; refreshes the
  /// LRU ordering for the entry.
  ///
  /// Returns null on miss or expiry. An expired entry is evicted as a side
  /// effect (and its key material zeroed).
  SignalSession? get(String key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (_now().difference(entry.lastAccessed) >= ttl) {
      _zeroAndDrop(entry);
      return null;
    }
    entry.lastAccessed = _now();
    _entries[key] = entry; // re-insert at end -> most recent
    return entry.session;
  }

  /// Insert or replace a session. Evicts the LRU entry when the cache exceeds
  /// [maxEntries]. If [key] already exists, the previous session's key
  /// material is zeroed before being replaced.
  void put(String key, SignalSession session) {
    final existing = _entries.remove(key);
    if (existing != null && !identical(existing.session, session)) {
      _zeroAndDrop(existing);
    }
    _entries[key] = _Entry(session, _now());
    while (_entries.length > maxEntries) {
      final firstKey = _entries.keys.first;
      final dropped = _entries.remove(firstKey)!;
      _zeroAndDrop(dropped);
    }
    _ensureSweepTimer();
  }

  /// Remove and zero a single entry. Returns whether anything was removed.
  bool remove(String key) {
    final entry = _entries.remove(key);
    if (entry == null) return false;
    _zeroAndDrop(entry);
    return true;
  }

  /// Apply [fn] to every cached session. Read-only iteration.
  void forEach(void Function(String key, SignalSession session) fn) {
    _entries.forEach((k, e) => fn(k, e.session));
  }

  /// True when [key] is present (does not refresh LRU order).
  bool containsKey(String key) => _entries.containsKey(key);

  /// Drop all expired entries. Called periodically by the sweep timer and
  /// exposed for tests.
  void evictExpired() {
    final now = _now();
    final expired = <String>[];
    for (final e in _entries.entries) {
      if (now.difference(e.value.lastAccessed) >= ttl) {
        expired.add(e.key);
      }
    }
    for (final k in expired) {
      _zeroAndDrop(_entries.remove(k)!);
    }
  }

  /// Zero and remove every entry. Used on logout or full reset.
  void clear() {
    for (final entry in _entries.values) {
      _zeroAndDrop(entry);
    }
    _entries.clear();
  }

  /// Cancel the periodic sweep and clear all entries. Safe to call multiple
  /// times.
  void dispose() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    clear();
  }

  void _zeroAndDrop(_Entry entry) {
    final s = entry.session;
    s.rootKey.fillRange(0, s.rootKey.length, 0);
    s.sendChainKey.fillRange(0, s.sendChainKey.length, 0);
    final recv = s.recvChainKey;
    if (recv != null) {
      recv.fillRange(0, recv.length, 0);
    }
    for (final mk in s.skippedKeys.values) {
      mk.fillRange(0, mk.length, 0);
    }
    s.skippedKeys.clear();
  }
}

class _Entry {
  final SignalSession session;
  DateTime lastAccessed;
  _Entry(this.session, this.lastAccessed);
}
