/// Pure-function tests for [sanitizeReleaseBody], the regex pass that
/// strips GitHub-auto-generated noise from release-notes markdown
/// before the What's-New modal renders it.  No Flutter binding needed.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/update_provider.dart';

void main() {
  group('sanitizeReleaseBody', () {
    test('returns null on null input', () {
      expect(sanitizeReleaseBody(null), isNull);
    });

    test('returns null on empty / whitespace-only input', () {
      expect(sanitizeReleaseBody(''), isNull);
      expect(sanitizeReleaseBody('   \n\n\t'), isNull);
    });

    test('strips the Full Changelog trailer', () {
      const raw = '''
## What's Changed
* fix: thing by @npc in #42

**Full Changelog**: https://github.com/NC1107/echo-messenger/compare/v0.0.301...v0.0.302
''';
      final out = sanitizeReleaseBody(raw)!;
      expect(out, contains('## What\'s Changed'));
      expect(out, isNot(contains('Full Changelog')));
      expect(out, isNot(contains('compare/v0.0.301')));
    });

    test('strips Dependabot bump diff lines', () {
      const raw = '''
## Bumps
- [tokio](https://github.com/tokio-rs/tokio/compare/tokio-1.50.0...tokio-1.52.2)
- [serde](https://github.com/serde-rs/serde/compare/v1.0.0...v1.0.1)

Real human commit message here.
''';
      final out = sanitizeReleaseBody(raw)!;
      expect(out, contains('## Bumps'));
      expect(out, contains('Real human commit message here.'));
      // Bumps shouldn't appear in body — only diff URL lines are
      // stripped; the headline survives, which is fine.
      expect(out, isNot(contains('tokio-rs/tokio/compare')));
      expect(out, isNot(contains('serde-rs/serde/compare')));
    });

    test('strips Co-Authored-By trailers', () {
      const raw = '''
fix: something

Co-Authored-By: dev <dev@example.com>
Co-Authored-By: Other Dev <other@example.com>

More content.
''';
      final out = sanitizeReleaseBody(raw)!;
      expect(out, isNot(contains('Co-Authored-By')));
      expect(out, contains('More content.'));
    });

    test('preserves regular markdown headers, lists, and code', () {
      const raw = '''
## What's Changed
- Feature: PiP mode for voice calls
- Fix: `MessageList` rebuild storm

```dart
final foo = 'bar';
```

Inline `code` example.
''';
      final out = sanitizeReleaseBody(raw)!;
      expect(out, contains("## What's Changed"));
      expect(out, contains('- Feature: PiP mode for voice calls'));
      expect(out, contains('```dart'));
      expect(out, contains('Inline `code` example.'));
    });

    test('collapses runs of blank lines', () {
      const raw = 'Line 1\n\n\n\n\nLine 2';
      final out = sanitizeReleaseBody(raw)!;
      expect(out, 'Line 1\n\nLine 2');
    });

    test('returns null when sanitization leaves nothing meaningful', () {
      const raw = '''


**Full Changelog**: https://github.com/x/y/compare/v1...v2


''';
      expect(sanitizeReleaseBody(raw), isNull);
    });

    test('handles a realistic compound release body', () {
      const raw = '''
## What's Changed
* fix(ios): drop invalid `picture-in-picture` UIBackgroundMode by @npc in #841
* feat(client): density tiers on voice control dock by @npc in #823

### Dependency bumps
- [tokio](https://github.com/tokio-rs/tokio/compare/tokio-1.50.0...tokio-1.52.2)

Co-Authored-By: dev <dev@example.com>

**Full Changelog**: https://github.com/NC1107/echo-messenger/compare/v0.0.301...v0.0.302
''';
      final out = sanitizeReleaseBody(raw)!;
      expect(out, contains('* fix(ios): drop invalid `picture-in-picture`'));
      expect(
        out,
        contains('* feat(client): density tiers on voice control dock'),
      );
      expect(out, contains('### Dependency bumps'));
      expect(out, isNot(contains('Full Changelog')));
      expect(out, isNot(contains('Co-Authored-By')));
      expect(out, isNot(contains('tokio-rs/tokio/compare')));
    });
  });
}
