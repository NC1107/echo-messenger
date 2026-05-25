import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/debug_log_service.dart';
import 'package:echo_app/src/widgets/feedback_dialog.dart';

void main() {
  group('deriveFeedbackTitle', () {
    test('returns trimmed first non-empty line verbatim when short enough', () {
      expect(deriveFeedbackTitle('Hello world'), 'Hello world');
      expect(deriveFeedbackTitle('\n\n  Hello\nrest'), 'Hello');
    });

    test('truncates long lines with a single-character ellipsis', () {
      final long = 'a' * 200;
      final title = deriveFeedbackTitle(long);
      expect(title.length, 80);
      expect(title.endsWith('…'), isTrue);
      expect(title.substring(0, 79), 'a' * 79);
    });

    test('returns empty string when no non-empty line exists', () {
      expect(deriveFeedbackTitle(''), '');
      expect(deriveFeedbackTitle('   \n\t\n   '), '');
    });
  });

  group('buildFeedbackPayload', () {
    late DebugLogService logs;

    setUp(() {
      logs = DebugLogService.instance;
      logs.resetForTest(overrideLogFilePath: null);
      logs.log(LogLevel.info, 'TestSource', 'first breadcrumb');
      logs.log(LogLevel.warning, 'TestSource', 'second breadcrumb');
    });

    tearDown(() {
      logs.resetForTest(overrideLogFilePath: null);
    });

    test('happy-path payload contains all expected fields', () {
      final payload = buildFeedbackPayload(
        body: '  Cursor jumps in landscape on iOS\nMore detail here  ',
        shareLogs: true,
        appVersion: '0.0.999',
        platformName: 'linux',
        logService: logs,
      );

      expect(payload['title'], 'Cursor jumps in landscape on iOS');
      expect(
        payload['body'],
        'Cursor jumps in landscape on iOS\nMore detail here',
      );
      expect(payload['public_ok'], false);
      expect(payload['app_version'], '0.0.999');
      expect(payload['platform'], 'linux');
      expect(payload['logs'], isA<String>());
      final logsStr = payload['logs'] as String;
      expect(logsStr, contains('first breadcrumb'));
      expect(logsStr, contains('[WRN]'));
      expect(logsStr, contains('TestSource'));
    });

    test('omits logs key when share-logs toggle is OFF', () {
      final payload = buildFeedbackPayload(
        body: 'A bug',
        shareLogs: false,
        appVersion: '0.0.999',
        platformName: 'web',
        logService: logs,
      );

      expect(payload.containsKey('logs'), isFalse);
      expect(payload['title'], 'A bug');
      expect(payload['public_ok'], false);
      expect(payload['app_version'], '0.0.999');
      expect(payload['platform'], 'web');
    });

    test('omits logs key when buffer is empty', () {
      logs.resetForTest(overrideLogFilePath: null);
      final payload = buildFeedbackPayload(
        body: 'A bug',
        shareLogs: true,
        appVersion: '0.0.999',
        platformName: 'web',
        logService: logs,
      );

      expect(payload.containsKey('logs'), isFalse);
    });

    test('truncates derived title to 80 chars with ellipsis', () {
      final long = 'x' * 200;
      final payload = buildFeedbackPayload(
        body: long,
        shareLogs: false,
        appVersion: '0.0.999',
        platformName: 'web',
        logService: logs,
      );

      final title = payload['title'] as String;
      expect(title.length, 80);
      expect(title.endsWith('…'), isTrue);
    });
  });
}
