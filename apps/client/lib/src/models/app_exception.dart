sealed class AppException implements Exception {
  final String message;
  final Object? cause;
  const AppException(this.message, [this.cause]);

  @override
  String toString() => message;
}

class NetworkException extends AppException {
  const NetworkException(super.message, [super.cause]);
}

class AuthException extends AppException {
  const AuthException(super.message, [super.cause]);
}
