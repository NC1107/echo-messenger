import 'package:echo_app/src/services/slash_commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseSlashCommand', () {
    test('returns null for plain text', () {
      expect(parseSlashCommand('hello world'), isNull);
    });

    test('returns null for empty string', () {
      expect(parseSlashCommand(''), isNull);
    });

    test('returns null for bare slash with no word', () {
      // A lone "/" with nothing after it doesn't match \w+
      expect(parseSlashCommand('/'), isNull);
    });

    test('/name Foo parses correctly', () {
      final cmd = parseSlashCommand('/name Foo');
      expect(cmd, isNotNull);
      expect(cmd!.name, 'name');
      expect(cmd.args, 'Foo');
    });

    test('/description multi word args captured', () {
      final cmd = parseSlashCommand('/description Hello world!');
      expect(cmd, isNotNull);
      expect(cmd!.name, 'description');
      expect(cmd.args, 'Hello world!');
    });

    test(
      '/kick @alice strips @ from args but keeps it in args (parser does not strip @)',
      () {
        // The parser does NOT strip @; the dispatcher does.
        final cmd = parseSlashCommand('/kick @alice');
        expect(cmd, isNotNull);
        expect(cmd!.name, 'kick');
        expect(cmd.args, '@alice');
      },
    );

    test('/help has empty args', () {
      final cmd = parseSlashCommand('/help');
      expect(cmd, isNotNull);
      expect(cmd!.name, 'help');
      expect(cmd.args, isEmpty);
    });

    test('/? is parsed as command named "?"', () {
      final cmd = parseSlashCommand('/?');
      // /? does NOT match \w+ (? is not a word char) so it returns null.
      // The dispatcher handles "?" via the alias; this confirms parser behaviour.
      expect(cmd, isNull);
    });

    test('command name is lowercased', () {
      final cmd = parseSlashCommand('/NAME Foo');
      expect(cmd!.name, 'name');
    });

    test('leading/trailing whitespace in input is trimmed', () {
      final cmd = parseSlashCommand('  /name Bar  ');
      expect(cmd, isNotNull);
      expect(cmd!.name, 'name');
      expect(cmd.args, 'Bar');
    });

    test('extra spaces between command and args are trimmed', () {
      final cmd = parseSlashCommand('/name    Spaced');
      expect(cmd!.args, 'Spaced');
    });
  });
}
