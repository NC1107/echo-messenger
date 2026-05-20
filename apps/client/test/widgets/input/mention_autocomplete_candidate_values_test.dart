import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/widgets/input/mention_autocomplete.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for [MentionAutocomplete.candidateValues] — the static helper
/// the chat composer uses to compute the keyboard-accept target. The
/// candidate list and the rendered ListView MUST stay in sync; this
/// suite locks the contract (TD-23).
void main() {
  ConversationMember member(String username) =>
      ConversationMember(userId: 'u-$username', username: username);

  group('MentionAutocomplete.candidateValues', () {
    test('empty query returns all member usernames then broadcasts', () {
      final result = MentionAutocomplete.candidateValues([
        member('alice'),
        member('bob'),
        member('carol'),
      ], '');
      expect(result, ['alice', 'bob', 'carol', 'everyone', 'here']);
    });

    test('query "al" filters to alice, no matching broadcasts', () {
      final result = MentionAutocomplete.candidateValues([
        member('alice'),
        member('bob'),
      ], 'al');
      expect(result, ['alice']);
    });

    test('query "ev" surfaces only @everyone', () {
      final result = MentionAutocomplete.candidateValues([
        member('alice'),
      ], 'ev');
      expect(result, ['everyone']);
    });

    test('query "he" surfaces only @here', () {
      final result = MentionAutocomplete.candidateValues([
        member('alice'),
      ], 'he');
      expect(result, ['here']);
    });

    test('no-match query returns empty list', () {
      final result = MentionAutocomplete.candidateValues([
        member('alice'),
      ], 'zzz');
      expect(result, isEmpty);
    });

    test('empty member list + empty query returns broadcasts only', () {
      final result = MentionAutocomplete.candidateValues(const [], '');
      expect(result, ['everyone', 'here']);
    });

    test('matching is case-insensitive on members (lowercased query)', () {
      // `extractMentionQuery` always lowercases before passing in, so we
      // mirror that here. Member usernames are stored lowercase upstream.
      final result = MentionAutocomplete.candidateValues([
        member('alice'),
      ], 'a');
      expect(result, ['alice']);
    });

    test('member usernames are matched on prefix, not contains', () {
      final result = MentionAutocomplete.candidateValues([
        member('alice'),
        member('palice'),
      ], 'al');
      expect(result, ['alice']);
    });
  });
}
