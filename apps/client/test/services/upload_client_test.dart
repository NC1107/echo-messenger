import 'dart:convert';

import 'package:echo_app/src/services/upload_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build an [UploadClient] wired to a simple token/refresh pair.
///
/// [tokenValues] is consumed in order: the first call to tokenGetter
/// returns tokenValues[0], the second returns tokenValues[1], etc.
/// Pass a list with one element for tests that don't exercise the refresh path.
UploadClient _makeClient({
  List<String?> tokenValues = const ['test-token'],
  bool refreshResult = false,
  void Function()? onRefresh,
}) {
  var tokenIndex = 0;
  return UploadClient.withCallbacks(
    tokenGetter: () {
      final t = tokenValues[tokenIndex.clamp(0, tokenValues.length - 1)];
      tokenIndex++;
      return t;
    },
    refresher: () async {
      onRefresh?.call();
      return refreshResult;
    },
  );
}

http.Client _serverReturning(int status, Map<String, dynamic> json) =>
    MockClient((_) async => http.Response(jsonEncode(json), status));

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('UploadResult', () {
    test('toString includes all fields', () {
      const r = UploadResult(
        ok: true,
        url: 'https://example.com/img.jpg',
        statusCode: 200,
        errorMessage: null,
        errorCode: null,
      );
      expect(r.toString(), contains('ok: true'));
      expect(r.toString(), contains('url: https://example.com/img.jpg'));
      expect(r.toString(), contains('status: 200'));
    });

    test('ok:false carries error and code', () {
      const r = UploadResult(
        ok: false,
        statusCode: 400,
        errorMessage: 'bad request',
        errorCode: 'invalid-mime',
      );
      expect(r.ok, isFalse);
      expect(r.errorMessage, 'bad request');
      expect(r.errorCode, 'invalid-mime');
    });
  });

  group('UploadClient.withCallbacks -- success paths', () {
    test('returns ok:true with url on 200', () async {
      final client = _makeClient();
      await http.runWithClient(() async {
        final result = await client.uploadFile(
          serverUrl: 'http://localhost',
          path: '/api/media/upload',
          bytes: [1, 2, 3],
          fileName: 'test.png',
          mimeType: 'image/png',
        );
        expect(result.ok, isTrue);
        expect(result.url, '/media/uploaded.png');
        expect(result.statusCode, 200);
      }, () => _serverReturning(200, {'url': '/media/uploaded.png'}));
    });

    test('returns ok:true on 201', () async {
      final client = _makeClient();
      await http.runWithClient(() async {
        final result = await client.uploadFile(
          serverUrl: 'http://localhost',
          path: '/api/media/upload',
          bytes: [4, 5, 6],
          fileName: 'img.jpg',
          mimeType: 'image/jpeg',
        );
        expect(result.ok, isTrue);
        expect(result.statusCode, 201);
      }, () => _serverReturning(201, {'url': '/media/img.jpg'}));
    });

    test('extracts avatar_url from 2xx PUT body', () async {
      final client = _makeClient();
      await http.runWithClient(() async {
        final result = await client.uploadFile(
          serverUrl: 'http://localhost',
          path: '/api/users/me/avatar',
          bytes: [0xff, 0xd8],
          fileName: 'avatar.jpg',
          mimeType: 'image/jpeg',
          method: 'PUT',
          fieldName: 'avatar',
        );
        expect(result.ok, isTrue);
        expect(result.url, '/avatars/me.jpg');
      }, () => _serverReturning(200, {'avatar_url': '/avatars/me.jpg'}));
    });

    test('injects Authorization header', () async {
      final client = _makeClient(tokenValues: ['my-jwt']);
      String? capturedAuth;
      await http.runWithClient(
        () async {
          await client.uploadFile(
            serverUrl: 'http://localhost',
            path: '/api/media/upload',
            bytes: [1],
            fileName: 'f.png',
            mimeType: 'image/png',
            extraFields: {'conversation_id': 'conv-42'},
          );
        },
        () => MockClient((req) async {
          capturedAuth = req.headers['authorization'];
          return http.Response(jsonEncode({'url': '/media/f.png'}), 200);
        }),
      );
      expect(capturedAuth, 'Bearer my-jwt');
    });
  });

  group('UploadClient.withCallbacks -- error paths', () {
    test('returns ok:false with parsed error and code on 400', () async {
      final client = _makeClient();
      await http.runWithClient(
        () async {
          final result = await client.uploadFile(
            serverUrl: 'http://localhost',
            path: '/api/media/upload',
            bytes: [1],
            fileName: 'f.bin',
            mimeType: 'application/octet-stream',
          );
          expect(result.ok, isFalse);
          expect(result.statusCode, 400);
          expect(result.errorMessage, 'file too large');
          expect(result.errorCode, 'file-too-large');
        },
        () => _serverReturning(400, {
          'error': 'file too large',
          'code': 'file-too-large',
        }),
      );
    });

    test('returns ok:false immediately when token is null', () async {
      final client = _makeClient(tokenValues: [null]);
      // No HTTP call should be made.
      final result = await client.uploadFile(
        serverUrl: 'http://localhost',
        path: '/api/media/upload',
        bytes: [1],
        fileName: 'f.bin',
        mimeType: 'image/png',
      );
      expect(result.ok, isFalse);
      expect(result.errorMessage, 'Not authenticated');
    });

    test(
      'returns ok:false with null errorMessage on non-JSON 500 body',
      () async {
        final client = _makeClient();
        await http.runWithClient(
          () async {
            final result = await client.uploadFile(
              serverUrl: 'http://localhost',
              path: '/api/media/upload',
              bytes: [1],
              fileName: 'f.png',
              mimeType: 'image/png',
            );
            expect(result.ok, isFalse);
            expect(result.statusCode, 500);
            expect(result.errorMessage, isNull);
          },
          () => MockClient(
            (_) async => http.Response('Internal Server Error', 500),
          ),
        );
      },
    );
  });

  group('UploadClient.withCallbacks -- 401 refresh cycle', () {
    test('retries with refreshed token after 401 and succeeds', () async {
      var refreshCalled = false;
      final client = _makeClient(
        tokenValues: ['old-token', 'refreshed-token'],
        refreshResult: true,
        onRefresh: () => refreshCalled = true,
      );

      var callCount = 0;
      await http.runWithClient(
        () async {
          final result = await client.uploadFile(
            serverUrl: 'http://localhost',
            path: '/api/media/upload',
            bytes: [1],
            fileName: 'f.png',
            mimeType: 'image/png',
          );
          expect(result.ok, isTrue);
          expect(result.url, '/media/f.png');
          expect(refreshCalled, isTrue);
          expect(callCount, 2); // 401 on first, 200 on retry
        },
        () => MockClient((_) async {
          callCount++;
          if (callCount == 1) {
            return http.Response(
              jsonEncode({'error': 'token expired', 'code': 'token-expired'}),
              401,
            );
          }
          return http.Response(jsonEncode({'url': '/media/f.png'}), 200);
        }),
      );
    });

    test('returns token-expired result when refresh fails after 401', () async {
      var refreshCalled = false;
      final client = _makeClient(
        tokenValues: ['old-token'],
        refreshResult: false,
        onRefresh: () => refreshCalled = true,
      );

      await http.runWithClient(
        () async {
          final result = await client.uploadFile(
            serverUrl: 'http://localhost',
            path: '/api/media/upload',
            bytes: [1],
            fileName: 'f.png',
            mimeType: 'image/png',
          );
          expect(result.ok, isFalse);
          expect(result.statusCode, 401);
          expect(result.errorCode, 'token-expired');
          expect(refreshCalled, isTrue);
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({'error': 'unauthorized', 'code': 'token-expired'}),
            401,
          ),
        ),
      );
    });
  });

  group('UploadClient.withCallbacks -- progress reporting', () {
    test('onProgress callback fires during chunked upload', () async {
      final client = _makeClient();
      final progressUpdates = <int>[];

      await http.runWithClient(() async {
        final result = await client.uploadFile(
          serverUrl: 'http://localhost',
          path: '/api/media/upload',
          bytes: List.generate(200 * 1024, (i) => i % 256),
          fileName: 'large.bin',
          mimeType: 'application/octet-stream',
          onProgress: (sent, total) => progressUpdates.add(sent),
        );
        expect(result.ok, isTrue);
      }, () => _serverReturning(200, {'url': '/media/large.bin'}));

      expect(progressUpdates, isNotEmpty);
      expect(progressUpdates.last, 200 * 1024);
    });
  });
}
