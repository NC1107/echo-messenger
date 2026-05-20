import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/message/poll_widget.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

/// Pump a [PollWidget] without any backing server. The widget's initState
/// fires an HTTP GET to `serverUrl`; under [TestWidgetsFlutterBinding] every
/// HTTP request returns a synthetic 400, so the load resolves to the error
/// branch immediately after the first frame.
Future<void> _pumpPollAndSettle(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: const Scaffold(
        body: PollWidget(
          messageId: 'm-1',
          serverUrl: 'http://127.0.0.1:0',
          authToken: 'tok',
          question: 'Pick one',
          options: ['A', 'B'],
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('parsePollTag', () {
    test('parses a valid poll tag', () {
      final result = parsePollTag('[poll:"Lunch?"|Pizza|Sushi|Salad]');
      expect(result, isNotNull);
      expect(result!.question, 'Lunch?');
      expect(result.options, ['Pizza', 'Sushi', 'Salad']);
    });

    test('trims whitespace inside option list', () {
      final result = parsePollTag('[poll:"Q"| A | B | C ]');
      expect(result, isNotNull);
      expect(result!.options, ['A', 'B', 'C']);
    });

    test('drops empty options after split', () {
      final result = parsePollTag('[poll:"Q"|A||B]');
      expect(result, isNotNull);
      expect(result!.options, ['A', 'B']);
    });

    test('returns null when question is empty', () {
      expect(parsePollTag('[poll:""|A|B]'), isNull);
    });

    test('returns null when there are fewer than two options', () {
      expect(parsePollTag('[poll:"Q"|A]'), isNull);
      expect(parsePollTag('[poll:"Q"|]'), isNull);
    });

    test('returns null on malformed input', () {
      expect(parsePollTag('not a poll'), isNull);
      expect(parsePollTag('[poll:Q|A|B]'), isNull); // no quotes around Q
      expect(parsePollTag('[poll:"Q"|A|B'), isNull); // missing trailing ]
    });
  });

  group('isPollContent', () {
    test('detects the poll tag prefix', () {
      expect(isPollContent('[poll:"Q"|A|B]'), isTrue);
    });

    test('tolerates leading whitespace', () {
      expect(isPollContent('   [poll:"Q"|A|B]'), isTrue);
    });

    test('rejects unrelated content', () {
      expect(isPollContent('hello world'), isFalse);
      expect(isPollContent('[other:foo]'), isFalse);
      expect(isPollContent(''), isFalse);
    });
  });

  group('PollWidget rendering', () {
    testWidgets('renders the styled shell around its content', (tester) async {
      // We can't load real poll data in a unit test (HTTP returns 400),
      // but the widget should still mount its outer shell and render the
      // error-state copy from `_loadOrCreate`'s 400-branch.
      await _pumpPollAndSettle(tester);
      // Either we're showing the error string or some load-state surface
      // — confirm the build path produced a Container shell either way.
      expect(find.byType(PollWidget), findsOneWidget);
      expect(find.textContaining('Could not load poll'), findsOneWidget);
    });
  });
}
