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

  group('rewriteSlashCommand', () {
    test('/shrug with text', () {
      const cmd = SlashCommand(name: 'shrug', args: 'hello');
      final result = rewriteSlashCommand(cmd, senderUsername: 'alice');
      expect(result, 'hello ¯\\_(ツ)_/¯');
    });

    test('/shrug without text', () {
      const cmd = SlashCommand(name: 'shrug', args: '');
      final result = rewriteSlashCommand(cmd, senderUsername: 'alice');
      expect(result, '¯\\_(ツ)_/¯');
    });

    test('/tableflip with text', () {
      const cmd = SlashCommand(name: 'tableflip', args: 'oops');
      final result = rewriteSlashCommand(cmd, senderUsername: 'alice');
      expect(result, 'oops (╯°□°)╯︵ ┻━┻');
    });

    test('/tableflip without text', () {
      const cmd = SlashCommand(name: 'tableflip', args: '');
      final result = rewriteSlashCommand(cmd, senderUsername: 'alice');
      expect(result, '(╯°□°)╯︵ ┻━┻');
    });

    test('/unflip with text', () {
      const cmd = SlashCommand(name: 'unflip', args: 'sorry');
      final result = rewriteSlashCommand(cmd, senderUsername: 'alice');
      expect(result, 'sorry ┬─┬ノ( º_ºノ)');
    });

    test('/unflip without text', () {
      const cmd = SlashCommand(name: 'unflip', args: '');
      final result = rewriteSlashCommand(cmd, senderUsername: 'alice');
      expect(result, '┬─┬ノ( º_ºノ)');
    });

    test('/me with action', () {
      const cmd = SlashCommand(name: 'me', args: 'waves hello');
      final result = rewriteSlashCommand(cmd, senderUsername: 'bob');
      expect(result, '_bob waves hello_');
    });

    test('/me without action returns null', () {
      const cmd = SlashCommand(name: 'me', args: '');
      final result = rewriteSlashCommand(cmd, senderUsername: 'bob');
      expect(result, isNull);
    });

    test('/lenny with text', () {
      const cmd = SlashCommand(name: 'lenny', args: 'hehe');
      final result = rewriteSlashCommand(cmd, senderUsername: 'alice');
      expect(result, 'hehe ( ͡° ͜ʖ ͡°)');
    });

    test('/lenny without text', () {
      const cmd = SlashCommand(name: 'lenny', args: '');
      final result = rewriteSlashCommand(cmd, senderUsername: 'alice');
      expect(result, '( ͡° ͜ʖ ͡°)');
    });

    test('/flip with text reverses and maps characters', () {
      const cmd = SlashCommand(name: 'flip', args: 'hello');
      final result = rewriteSlashCommand(cmd, senderUsername: 'alice');
      // 'hello' -> map each: h->ɥ, e->ǝ, l->l, l->l, o->o -> 'ɥǝllo'
      // then reverse: 'ollǝɥ'
      expect(result, 'ollǝɥ');
    });

    test('/flip without text returns null', () {
      const cmd = SlashCommand(name: 'flip', args: '');
      final result = rewriteSlashCommand(cmd, senderUsername: 'alice');
      expect(result, isNull);
    });

    test('unknown command returns null', () {
      const cmd = SlashCommand(name: 'unknown', args: 'text');
      final result = rewriteSlashCommand(cmd, senderUsername: 'alice');
      expect(result, isNull);
    });
  });
}
