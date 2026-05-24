import 'package:echo_app/src/utils/platform_shutdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('registerSigtermHandler', () {
    test('does not throw on the host platform', () {
      expect(() => registerSigtermHandler(() {}), returnsNormally);
    });
  });
}
