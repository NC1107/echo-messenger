// Unit tests for the conversation navigation history model introduced in
// home_screen.dart + actions.dart.
//
// The history lives in `_HomeScreenState` as a `List<String>` (IDs) +
// `_navHistoryIndex`.  Rather than spinning up a full widget test, we
// mirror the same rules in a pure-Dart test using a helper that reproduces
// the three operations:
//   - push      → _pushNavHistory (called from _selectConversation)
//   - goBack    → _jumpHistory(forward: false)
//   - goForward → _jumpHistory(forward: true)
//
// Covered:
//   1. Pushing to an empty history starts at index 0.
//   2. Pushing the same ID twice is a no-op (no duplicates at same position).
//   3. Pushing a new ID advances the index.
//   4. Push truncates forward entries (browser model).
//   5. History is capped at _navHistoryLimit (50).
//   6. canGoBack / canGoForward flags reflect the index correctly.
//   7. Back navigates to the previous entry.
//   8. Forward navigates to the next entry after a back.
//   9. Back/forward are no-ops at the boundaries.
//  10. goBack skips deleted conversation IDs and continues walking.
//  11. goForward skips deleted conversation IDs and continues walking.

import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Minimal simulation of the history stack logic
// ---------------------------------------------------------------------------

const int _navHistoryLimit = 50;

/// Mirrors _HomeScreenState's nav history fields.
class _NavState {
  final List<String> history = [];
  int index = -1;

  bool get canGoBack => index > 0;
  bool get canGoForward => index < history.length - 1;

  /// Push [id] onto history, truncating forward entries.
  void push(String id) {
    // Skip if re-selecting the current conversation.
    if (index >= 0 && history[index] == id) return;

    // Truncate forward entries.
    if (index < history.length - 1) {
      history.removeRange(index + 1, history.length);
    }

    history.add(id);

    // Cap.
    if (history.length > _navHistoryLimit) {
      history.removeAt(0);
    }

    index = history.length - 1;
  }

  /// Move back/forward, skipping [deletedIds].
  ///
  /// Returns the landed conversation ID, or null when at a boundary.
  String? jump({required bool forward, Set<String> deletedIds = const {}}) {
    var idx = index;
    while (true) {
      idx = forward ? idx + 1 : idx - 1;
      if (idx < 0 || idx >= history.length) return null;

      final targetId = history[idx];
      if (!deletedIds.contains(targetId)) {
        index = idx;
        return targetId;
      }
      // Skip deleted entry and keep walking.
    }
  }

  String? goBack({Set<String> deletedIds = const {}}) =>
      jump(forward: false, deletedIds: deletedIds);

  String? goForward({Set<String> deletedIds = const {}}) =>
      jump(forward: true, deletedIds: deletedIds);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('conversation navigation history', () {
    test('1. pushing to empty history starts at index 0', () {
      final s = _NavState();
      s.push('a');
      expect(s.index, 0);
      expect(s.history, ['a']);
    });

    test('2. pushing the same id twice is a no-op', () {
      final s = _NavState();
      s.push('a');
      s.push('a'); // duplicate of current
      expect(s.history.length, 1);
      expect(s.index, 0);
    });

    test('3. pushing a new id advances the index', () {
      final s = _NavState();
      s.push('a');
      s.push('b');
      expect(s.history, ['a', 'b']);
      expect(s.index, 1);
    });

    test('4. push truncates forward entries (browser model)', () {
      final s = _NavState();
      s.push('a');
      s.push('b');
      s.push('c');
      s.goBack(); // index → 1 (b)
      s.push('d'); // truncates 'c', appends 'd'
      expect(s.history, ['a', 'b', 'd']);
      expect(s.index, 2);
    });

    test('5. history is capped at $_navHistoryLimit entries', () {
      final s = _NavState();
      for (var i = 0; i < _navHistoryLimit + 5; i++) {
        s.push('conv-$i');
      }
      expect(s.history.length, _navHistoryLimit);
      // Oldest entry was dropped; newest is at the end.
      expect(s.history.last, 'conv-${_navHistoryLimit + 4}');
    });

    group('canGoBack / canGoForward', () {
      test('6a. false / false on single entry', () {
        final s = _NavState();
        s.push('a');
        expect(s.canGoBack, isFalse);
        expect(s.canGoForward, isFalse);
      });

      test('6b. after two pushes, canGoBack true, canGoForward false', () {
        final s = _NavState();
        s.push('a');
        s.push('b');
        expect(s.canGoBack, isTrue);
        expect(s.canGoForward, isFalse);
      });

      test('6c. after goBack, canGoBack false, canGoForward true', () {
        final s = _NavState();
        s.push('a');
        s.push('b');
        s.goBack();
        expect(s.canGoBack, isFalse);
        expect(s.canGoForward, isTrue);
      });
    });

    test('7. goBack navigates to the previous entry', () {
      final s = _NavState();
      s.push('a');
      s.push('b');
      final landed = s.goBack();
      expect(landed, 'a');
      expect(s.index, 0);
    });

    test('8. goForward navigates to the next entry after a back', () {
      final s = _NavState();
      s.push('a');
      s.push('b');
      s.goBack();
      final landed = s.goForward();
      expect(landed, 'b');
      expect(s.index, 1);
    });

    group('boundary no-ops', () {
      test('9a. goBack at index 0 returns null', () {
        final s = _NavState();
        s.push('a');
        expect(s.goBack(), isNull);
        expect(s.index, 0); // unchanged
      });

      test('9b. goForward at the end returns null', () {
        final s = _NavState();
        s.push('a');
        s.push('b');
        expect(s.goForward(), isNull);
        expect(s.index, 1); // unchanged
      });

      test('9c. empty history goBack returns null without error', () {
        final s = _NavState();
        expect(s.goBack(), isNull);
      });
    });

    test(
      '10. goBack skips deleted conversations and lands on next live one',
      () {
        final s = _NavState();
        s.push('a');
        s.push('b'); // deleted
        s.push('c');
        // At index 2 (c). Going back: b is deleted → should land on a.
        final landed = s.goBack(deletedIds: {'b'});
        expect(landed, 'a');
        expect(s.index, 0);
      },
    );

    test('11. goForward skips deleted conversations', () {
      final s = _NavState();
      s.push('a');
      s.push('b'); // deleted
      s.push('c');
      s.goBack(deletedIds: {}); // move to b (index 1)
      s.goBack(deletedIds: {}); // move to a (index 0)
      // Forward: b is deleted → should land on c (index 2).
      final landed = s.goForward(deletedIds: {'b'});
      expect(landed, 'c');
      expect(s.index, 2);
    });

    test(
      '11b. goForward returns null when all forward entries are deleted',
      () {
        final s = _NavState();
        s.push('a');
        s.push('b'); // deleted
        s.goBack(); // back to a
        final landed = s.goForward(deletedIds: {'b'});
        expect(landed, isNull);
        expect(s.index, 0); // unchanged
      },
    );
  });
}
