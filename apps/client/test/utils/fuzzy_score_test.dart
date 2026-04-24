import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/utils/fuzzy_score.dart';

void main() {
  group('fuzzyScore', () {
    test('returns 0 for empty query', () {
      expect(fuzzyScore('', 'anything'), 0);
    });

    test('returns 0 when query has characters not present in order', () {
      expect(fuzzyScore('xyz', 'abc'), 0);
      // 'ba' not found in 'abc' (would need 'b' before 'a')
      expect(fuzzyScore('ba', 'abc'), 0);
    });

    test('perfect prefix match scores 1.0', () {
      expect(fuzzyScore('abc', 'abc'), closeTo(1.0, 0.001));
      expect(fuzzyScore('ali', 'alice'), closeTo(1.0, 0.001));
    });

    test('is case-insensitive', () {
      expect(fuzzyScore('ALICE', 'alice'), closeTo(1.0, 0.001));
      expect(fuzzyScore('Alice', 'ALICE'), closeTo(1.0, 0.001));
    });

    test('consecutive matches score higher than scattered', () {
      final consecutive = fuzzyScore('ace', 'aceAAA');
      final scattered = fuzzyScore('ace', 'a_c_e');
      expect(consecutive, greaterThan(scattered));
    });

    test('substring match in middle still returns positive score', () {
      final s = fuzzyScore('bob', 'alice-bob-charlie');
      expect(s, greaterThan(0));
      expect(s, lessThanOrEqualTo(1.0));
    });

    test('single-character query always returns a valid score', () {
      expect(fuzzyScore('a', 'a'), closeTo(1.0, 0.001));
      expect(fuzzyScore('a', 'abc'), closeTo(1.0, 0.001));
      expect(fuzzyScore('a', 'b'), 0);
    });

    test('score is clamped to [0, 1]', () {
      for (final pair in [
        ['a', 'a'],
        ['abc', 'abc'],
        ['ab', 'abababab'],
        ['', 'anything'],
        ['xyz', 'abc'],
      ]) {
        final s = fuzzyScore(pair[0], pair[1]);
        expect(s, greaterThanOrEqualTo(0));
        expect(s, lessThanOrEqualTo(1.0));
      }
    });

    test('sorts candidates so best match is first', () {
      const query = 'ali';
      final candidates = ['bob', 'charlie', 'alice', 'alinka'];
      final scored =
          candidates.map((c) => (name: c, score: fuzzyScore(query, c))).toList()
            ..sort((a, b) => b.score.compareTo(a.score));

      // alice / alinka both have 'ali' as prefix; bob has no match.
      expect(scored.first.name, anyOf('alice', 'alinka'));
      expect(scored.last.name, 'bob');
      expect(scored.last.score, 0);
    });
  });
}
