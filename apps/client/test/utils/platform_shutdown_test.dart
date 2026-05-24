import 'package:echo_app/src/utils/platform_shutdown.dart';
import 'package:echo_app/src/utils/platform_shutdown_stub.dart' as stub;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('registerSigtermHandler', () {
    test('does not throw on the host platform', () {
      expect(() => registerSigtermHandler(() {}), returnsNormally);
    });
  });

  group('platform_shutdown_stub', () {
    test('never invokes the callback (web/Windows no-op contract)', () {
      var called = false;
      stub.registerSigtermHandler(() => called = true);
      expect(called, isFalse);
    });
  });
}
