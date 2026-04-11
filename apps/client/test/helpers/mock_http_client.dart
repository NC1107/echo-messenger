import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';

/// Mock HTTP client for use with `http.runWithClient`.
class MockHttpClient extends Mock implements http.Client {}

/// Register fallback values needed by mocktail for HTTP types.
///
/// Call this in `setUpAll` before using `any()` matchers with URI arguments.
void registerHttpFallbackValues() {
  registerFallbackValue(Uri.parse('http://localhost'));
}
