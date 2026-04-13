import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/models/app_exception.dart';

void main() {
  group('AppException', () {
    test('message is stored and returned by toString', () {
      const ex = NetworkException('connection refused');
      expect(ex.message, 'connection refused');
      expect(ex.toString(), 'connection refused');
    });

    test('cause is stored when provided', () {
      final cause = Exception('root cause');
      const ex = AuthException('auth failed', 'root cause');
      expect(ex.message, 'auth failed');
      expect(ex.cause, 'root cause');
    });

    test('cause is null when not provided', () {
      const ex = NetworkException('timeout');
      expect(ex.cause, isNull);
    });
  });

  group('NetworkException', () {
    test('is a subtype of AppException', () {
      const ex = NetworkException('network error');
      expect(ex, isA<AppException>());
      expect(ex, isA<Exception>());
    });

    test('toString returns the message', () {
      const ex = NetworkException('unreachable');
      expect(ex.toString(), 'unreachable');
    });

    test('can be caught as AppException', () {
      void throwNetwork() => throw const NetworkException('down');
      expect(throwNetwork, throwsA(isA<AppException>()));
      expect(throwNetwork, throwsA(isA<NetworkException>()));
    });
  });

  group('AuthException', () {
    test('is a subtype of AppException', () {
      const ex = AuthException('token expired');
      expect(ex, isA<AppException>());
    });

    test('toString returns the message', () {
      const ex = AuthException('unauthorized');
      expect(ex.toString(), 'unauthorized');
    });

    test('can be caught as AppException', () {
      void throwAuth() => throw const AuthException('expired');
      expect(throwAuth, throwsA(isA<AppException>()));
      expect(throwAuth, throwsA(isA<AuthException>()));
    });

    test('NetworkException and AuthException are distinct types', () {
      const net = NetworkException('net');
      const auth = AuthException('auth');
      expect(net, isNot(isA<AuthException>()));
      expect(auth, isNot(isA<NetworkException>()));
    });
  });
}
