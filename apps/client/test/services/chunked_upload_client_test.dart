// Unit tests for ChunkedUploadClient.
//
// Uses a hand-rolled `MockClient` in place of the production `http.Client`
// so we never make a real network call.  Each test asserts on (a) the
// request shape the client sends and (b) how the client reacts to a
// scripted response sequence.

import 'dart:convert';

import 'package:echo_app/src/services/chunked_upload_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Helper: build a [ChunkedUploadClient] backed by a [MockClient] whose
/// handler is supplied by the caller.  The mock records every request so
/// individual tests can assert on the sent sequence.
ChunkedUploadClient _client({
  required Future<http.Response> Function(http.Request) handler,
  List<http.Request>? sink,
}) {
  final mock = MockClient((request) {
    sink?.add(request);
    return handler(request);
  });
  return ChunkedUploadClient.withCallbacks(
    tokenGetter: () => 'tok',
    refresher: () async => true,
    transport: () => mock,
  );
}

void main() {
  group('ChunkedUploadClient.uploadBytes', () {
    test('chunked threshold defaults to 5 MB', () {
      expect(kChunkedUploadThresholdBytes, 5 * 1024 * 1024);
    });

    test('shouldUseChunkedUpload includes exact threshold boundary', () {
      expect(shouldUseChunkedUpload(kChunkedUploadThresholdBytes - 1), isFalse);
      expect(shouldUseChunkedUpload(kChunkedUploadThresholdBytes), isTrue);
    });

    test(
      'happy path issues init + chunk(s) + finalize and returns url',
      () async {
        final calls = <http.Request>[];
        final bytes = List<int>.generate(12, (i) => i);

        final client = _client(
          sink: calls,
          handler: (req) async {
            if (req.url.path.endsWith('/api/media/upload/init')) {
              return http.Response(
                jsonEncode({'upload_id': 'upl-1', 'chunk_size': 5}),
                201,
              );
            }
            if (req.url.path.endsWith('/chunk')) {
              // Server echoes how many bytes have landed so far.  Compute
              // the expected count from the Content-Range header.
              final range = req.headers['content-range']!;
              final endPart = range.split('/').first.split('-').last;
              final received = int.parse(endPart) + 1;
              return http.Response(
                jsonEncode({'bytes_received': received}),
                200,
              );
            }
            if (req.url.path.endsWith('/finalize')) {
              return http.Response(
                jsonEncode({'id': 'media-1', 'url': '/api/media/media-1'}),
                201,
              );
            }
            return http.Response('not found', 404);
          },
        );

        final result = await client.uploadBytes(
          bytes: bytes,
          serverUrl: 'https://example.test',
          mimeType: 'image/png',
          filename: 'a.png',
        );

        expect(result.ok, isTrue);
        expect(result.url, '/api/media/media-1');
        // 12 bytes with chunk_size=5 → 5 + 5 + 2 → 3 chunk PATCHes + init + finalize.
        final patches = calls.where((r) => r.method == 'PATCH').toList();
        expect(patches, hasLength(3));
        expect(patches.first.headers['content-range'], 'bytes 0-4/12');
        expect(patches[1].headers['content-range'], 'bytes 5-9/12');
        expect(patches[2].headers['content-range'], 'bytes 10-11/12');
      },
    );

    test(
      'chunk failure retries the same offset up to maxRetriesPerChunk',
      () async {
        final calls = <http.Request>[];
        var chunkAttempts = 0;
        final bytes = List<int>.generate(4, (i) => i);

        final client = _client(
          sink: calls,
          handler: (req) async {
            if (req.url.path.endsWith('/init')) {
              return http.Response(
                jsonEncode({'upload_id': 'upl-2', 'chunk_size': 4}),
                201,
              );
            }
            if (req.url.path.endsWith('/chunk')) {
              chunkAttempts++;
              // Fail twice, succeed on the third.
              if (chunkAttempts < 3) {
                return http.Response('boom', 502);
              }
              return http.Response(jsonEncode({'bytes_received': 4}), 200);
            }
            if (req.url.path.endsWith('/finalize')) {
              return http.Response(
                jsonEncode({'id': 'm', 'url': '/api/media/m'}),
                201,
              );
            }
            return http.Response('not found', 404);
          },
        );

        final result = await client.uploadBytes(
          bytes: bytes,
          serverUrl: 'https://example.test',
          mimeType: 'image/png',
          filename: 'a.png',
          maxRetriesPerChunk: 3,
        );

        expect(result.ok, isTrue);
        // All three chunk PATCHes targeted the same byte range.
        final patches = calls.where((r) => r.method == 'PATCH').toList();
        expect(patches, hasLength(3));
        for (final p in patches) {
          expect(p.headers['content-range'], 'bytes 0-3/4');
        }
      },
    );

    test(
      '416 with bytes_received body re-syncs without an extra GET',
      () async {
        final calls = <http.Request>[];
        var firstChunkSeen = false;
        final bytes = List<int>.generate(10, (i) => i);

        final client = _client(
          sink: calls,
          handler: (req) async {
            if (req.url.path.endsWith('/init')) {
              return http.Response(
                jsonEncode({'upload_id': 'upl-3', 'chunk_size': 5}),
                201,
              );
            }
            if (req.url.path.endsWith('/chunk')) {
              if (!firstChunkSeen) {
                firstChunkSeen = true;
                // Pretend the server already has 3 bytes -- client should
                // advance the offset and ship the rest from there.
                return http.Response(jsonEncode({'bytes_received': 3}), 416);
              }
              final range = req.headers['content-range']!;
              final endPart = range.split('/').first.split('-').last;
              return http.Response(
                jsonEncode({'bytes_received': int.parse(endPart) + 1}),
                200,
              );
            }
            if (req.url.path.endsWith('/finalize')) {
              return http.Response(
                jsonEncode({'id': 'm', 'url': '/api/media/m'}),
                201,
              );
            }
            return http.Response('not found', 404);
          },
        );

        final result = await client.uploadBytes(
          bytes: bytes,
          serverUrl: 'https://example.test',
          mimeType: 'image/png',
          filename: 'a.png',
        );

        expect(result.ok, isTrue);
        // The client should have continued from offset 3, never doing a GET
        // re-sync (because the 416 body carried bytes_received already).
        final gets = calls.where((r) => r.method == 'GET').toList();
        expect(gets, isEmpty);
      },
    );

    test(
      '416 with empty body triggers GET re-sync from /api/media/upload/{id}',
      () async {
        final calls = <http.Request>[];
        var firstChunkSeen = false;

        final client = _client(
          sink: calls,
          handler: (req) async {
            if (req.url.path.endsWith('/init')) {
              return http.Response(
                jsonEncode({'upload_id': 'upl-4', 'chunk_size': 5}),
                201,
              );
            }
            if (req.method == 'GET') {
              return http.Response(
                jsonEncode({
                  'upload_id': 'upl-4',
                  'bytes_received': 2,
                  'total_size': 5,
                  'status': 'pending',
                }),
                200,
              );
            }
            if (req.url.path.endsWith('/chunk')) {
              if (!firstChunkSeen) {
                firstChunkSeen = true;
                // Empty 416 body — older server / hostile proxy.
                return http.Response('', 416);
              }
              final range = req.headers['content-range']!;
              final endPart = range.split('/').first.split('-').last;
              return http.Response(
                jsonEncode({'bytes_received': int.parse(endPart) + 1}),
                200,
              );
            }
            if (req.url.path.endsWith('/finalize')) {
              return http.Response(
                jsonEncode({'id': 'm', 'url': '/api/media/m'}),
                201,
              );
            }
            return http.Response('not found', 404);
          },
        );

        final result = await client.uploadBytes(
          bytes: List<int>.filled(5, 1),
          serverUrl: 'https://example.test',
          mimeType: 'image/png',
          filename: 'a.png',
        );

        expect(result.ok, isTrue);
        final gets = calls.where((r) => r.method == 'GET').toList();
        expect(
          gets,
          hasLength(1),
          reason: 'expected one fallback GET to re-sync bytes_received',
        );
      },
    );

    test('init failure short-circuits and surfaces the server error', () async {
      final client = _client(
        handler: (req) async {
          if (req.url.path.endsWith('/init')) {
            return http.Response(jsonEncode({'error': 'File too large'}), 400);
          }
          return http.Response('not reached', 500);
        },
      );

      final result = await client.uploadBytes(
        bytes: [1, 2, 3],
        serverUrl: 'https://example.test',
      );

      expect(result.ok, isFalse);
      expect(result.statusCode, 400);
      expect(result.errorMessage, contains('File too large'));
    });
  });
}
