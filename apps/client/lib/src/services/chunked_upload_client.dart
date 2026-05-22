// Chunked / resumable upload client (#556).
//
// Mirrors the three Rust endpoints on `/api/media/upload`:
//   1. POST   /init       → returns `{ upload_id, chunk_size }`
//   2. PATCH  /{id}/chunk → appends one chunk at the next offset
//   3. POST   /{id}/finalize → assembles the media row and returns
//      the same shape the legacy single-shot endpoint does
//   4. GET    /{id}       → re-sync after a 416 / crash
//
// The on-disk file is read incrementally in `chunk_size`-byte slices; no
// part of the upload ever sits in RAM longer than one chunk.  Each chunk
// gets up to [maxRetriesPerChunk] retries with exponential back-off; a
// 416 from the server triggers a fresh GET so the client can pick the
// right offset before retrying.
//
// The public return shape matches the existing [UploadClient.uploadFile]
// result so callers can switch between the two paths without branching on
// the return type.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;

import 'package:http/http.dart' as http;

import 'upload_client.dart';

/// Default back-off table used between chunk retries.  Kept module-private
/// because callers cannot meaningfully tune it -- the right knob is
/// [ChunkedUploadClient.maxRetriesPerChunk], not the schedule.
const List<Duration> _kRetryBackoffs = [
  Duration(milliseconds: 200),
  Duration(milliseconds: 800),
  Duration(seconds: 2),
];

/// Threshold (in bytes) at which a caller should prefer the chunked path
/// over the legacy single-shot multipart endpoint.  Kept 5 MB below
/// Cloudflare's 100 MB edge cap so a borderline file never reaches the
/// edge limit even after multipart framing overhead.
const int kChunkedUploadThresholdBytes = 95 * 1024 * 1024;

const String _kOctetStream = 'application/octet-stream';
const String _kJsonMime = 'application/json';
const String _kContentType = 'Content-Type';

/// Token getter callback shape.  Mirrors [UploadClient]'s tokenGetter so
/// the production wiring stays single-source-of-truth.
typedef ChunkedTokenGetter = String? Function();

/// Refresh callback shape, returning whether the refresh succeeded.
typedef ChunkedRefresher = Future<bool> Function();

/// HTTP transport hook -- only present so tests can swap in a mock client.
typedef ChunkedHttpTransport = http.Client Function();

/// Result returned by [ChunkedUploadClient.upload], deliberately shaped
/// identically to [UploadResult] so the chat-input bar can hand it back
/// to its existing success/error branches unchanged.
class ChunkedUploadResult {
  const ChunkedUploadResult({
    required this.ok,
    this.url,
    this.errorMessage,
    this.statusCode,
    this.width,
    this.height,
  });

  final bool ok;
  final String? url;
  final String? errorMessage;
  final int? statusCode;
  final int? width;
  final int? height;

  UploadResult toUploadResult() => UploadResult(
    ok: ok,
    url: url,
    statusCode: statusCode,
    errorMessage: errorMessage,
    width: width,
    height: height,
  );
}

class ChunkedUploadClient {
  /// Wire up against a live [UploadClient] / [AuthNotifier].  The token
  /// getter and refresher are reused so this client behaves identically
  /// w.r.t. 401 → refresh → retry as the single-shot path.
  ChunkedUploadClient({
    required ChunkedTokenGetter tokenGetter,
    required ChunkedRefresher refresher,
    http.Client? httpClient,
  }) : _tokenGetter = tokenGetter,
       _refresher = refresher,
       _transport = (() => httpClient ?? http.Client());

  /// Test-only seam: caller supplies a [ChunkedHttpTransport] so a mock can be
  /// injected without depending on production auth wiring.
  ChunkedUploadClient.withCallbacks({
    required ChunkedTokenGetter tokenGetter,
    required ChunkedRefresher refresher,
    required ChunkedHttpTransport transport,
  }) : _tokenGetter = tokenGetter,
       _refresher = refresher,
       _transport = transport;

  final ChunkedTokenGetter _tokenGetter;
  final ChunkedRefresher _refresher;
  final ChunkedHttpTransport _transport;

  /// Upload an in-memory [bytes] buffer using the chunked pipeline.  Same
  /// init / PATCH / finalize wire flow as [upload], but reads slices out of
  /// the in-memory buffer instead of a `dart:io` File.  Used by the chat
  /// composer, which already has the payload in RAM (the pickers stage it
  /// there for preview).
  Future<ChunkedUploadResult> uploadBytes({
    required List<int> bytes,
    required String serverUrl,
    String? mimeType,
    String? filename,
    String? conversationId,
    void Function(int sent, int total)? onProgress,
    int maxRetriesPerChunk = 3,
  }) async {
    final total = bytes.length;
    final declaredName = filename ?? 'upload.bin';
    final declaredMime = mimeType ?? _kOctetStream;

    final client = _transport();
    try {
      final init = await _initSession(
        client: client,
        serverUrl: serverUrl,
        filename: declaredName,
        mimeType: declaredMime,
        totalSize: total,
        conversationId: conversationId,
      );
      if (!init.ok) {
        return ChunkedUploadResult(
          ok: false,
          statusCode: init.statusCode,
          errorMessage: init.errorMessage,
        );
      }

      var sent = 0;
      while (sent < total) {
        final end = (sent + init.chunkSize).clamp(0, total).toInt();
        final chunk = bytes.sublist(sent, end);
        final chunkResult = await _sendChunkWithRetries(
          client: client,
          serverUrl: serverUrl,
          uploadId: init.uploadId,
          chunk: chunk,
          start: sent,
          total: total,
          maxRetries: maxRetriesPerChunk,
        );
        if (!chunkResult.ok) {
          return ChunkedUploadResult(
            ok: false,
            statusCode: chunkResult.statusCode,
            errorMessage: chunkResult.errorMessage,
          );
        }
        sent = chunkResult.bytesReceived;
        if (onProgress != null) onProgress(sent, total);
      }

      return _finalize(
        client: client,
        serverUrl: serverUrl,
        uploadId: init.uploadId,
      );
    } finally {
      client.close();
    }
  }

  /// Upload [file] in chunks.  Returns a [ChunkedUploadResult] mirroring
  /// the single-shot [UploadResult] shape so callers can branch on `ok`.
  ///
  /// [onProgress] receives `(sent, total)` byte counts after every chunk
  /// completes.  Per-chunk progress within a chunk is intentionally not
  /// surfaced -- the existing progress reporter consumes a coarse counter.
  Future<ChunkedUploadResult> upload({
    required File file,
    required String serverUrl,
    String? mimeType,
    String? filename,
    String? conversationId,
    void Function(int sent, int total)? onProgress,
    int maxRetriesPerChunk = 3,
  }) async {
    final total = await file.length();
    final declaredName = filename ?? file.uri.pathSegments.last;
    final declaredMime = mimeType ?? _kOctetStream;

    final client = _transport();
    try {
      final init = await _initSession(
        client: client,
        serverUrl: serverUrl,
        filename: declaredName,
        mimeType: declaredMime,
        totalSize: total,
        conversationId: conversationId,
      );
      if (!init.ok) {
        return ChunkedUploadResult(
          ok: false,
          statusCode: init.statusCode,
          errorMessage: init.errorMessage,
        );
      }

      var sent = 0;
      while (sent < total) {
        final end = (sent + init.chunkSize).clamp(0, total).toInt();
        final chunk = await _readSlice(file, sent, end);
        final chunkResult = await _sendChunkWithRetries(
          client: client,
          serverUrl: serverUrl,
          uploadId: init.uploadId,
          chunk: chunk,
          start: sent,
          total: total,
          maxRetries: maxRetriesPerChunk,
        );
        if (!chunkResult.ok) {
          return ChunkedUploadResult(
            ok: false,
            statusCode: chunkResult.statusCode,
            errorMessage: chunkResult.errorMessage,
          );
        }
        sent = chunkResult.bytesReceived;
        if (onProgress != null) onProgress(sent, total);
      }

      return _finalize(
        client: client,
        serverUrl: serverUrl,
        uploadId: init.uploadId,
      );
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Step 1: init
  // ---------------------------------------------------------------------------

  Future<_InitResult> _initSession({
    required http.Client client,
    required String serverUrl,
    required String filename,
    required String mimeType,
    required int totalSize,
    String? conversationId,
  }) async {
    final body = <String, dynamic>{
      'filename': filename,
      'mime_type': mimeType,
      'total_size': totalSize,
      'conversation_id': ?conversationId,
    };

    final resp = await _authedRequest(
      build: (token) =>
          http.Request('POST', Uri.parse('$serverUrl/api/media/upload/init'))
            ..headers['Authorization'] = 'Bearer $token'
            ..headers[_kContentType] = _kJsonMime
            ..body = jsonEncode(body),
      client: client,
    );
    final text = await resp.stream.bytesToString();
    if (resp.statusCode != 201 && resp.statusCode != 200) {
      return _InitResult.fail(
        statusCode: resp.statusCode,
        errorMessage: _extractError(text),
      );
    }
    final data = jsonDecode(text) as Map<String, dynamic>;
    return _InitResult.ok(
      uploadId: data['upload_id'] as String,
      chunkSize: (data['chunk_size'] as num).toInt(),
    );
  }

  // ---------------------------------------------------------------------------
  // Step 2: chunk (with retry + 416 re-sync)
  // ---------------------------------------------------------------------------

  Future<_ChunkResult> _sendChunkWithRetries({
    required http.Client client,
    required String serverUrl,
    required String uploadId,
    required List<int> chunk,
    required int start,
    required int total,
    required int maxRetries,
  }) async {
    var attempt = 0;
    var localStart = start;
    var localChunk = chunk;

    while (true) {
      final resp = await _sendOneChunk(
        client: client,
        serverUrl: serverUrl,
        uploadId: uploadId,
        chunk: localChunk,
        start: localStart,
        total: total,
      );

      if (resp.ok) return resp;

      // 416 → re-sync from server and adjust the offset.  This is a
      // one-shot correction; if the server tells us nothing, fall through
      // to the regular retry path.
      if (resp.statusCode == 416 && resp.bytesReceived >= 0) {
        final newStart = resp.bytesReceived;
        // Don't keep bytes we've already shipped.  If the server is ahead
        // of where we thought, advance; if behind, re-send the trailing
        // slice.
        if (newStart > localStart) {
          final advance = newStart - localStart;
          if (advance >= localChunk.length) {
            // Server already has more than we were about to send -- skip
            // this whole chunk and let the outer loop fetch the next.
            return _ChunkResult.ok(bytesReceived: newStart);
          }
          localChunk = localChunk.sublist(advance);
          localStart = newStart;
          continue;
        }
        // newStart < start: server lost progress; resume from there.
        // We don't have the missing bytes here, so the caller's outer
        // loop will re-derive the chunk on the next iteration.  Surface
        // a synthetic ok=true so the outer loop re-reads from disk.
        return _ChunkResult.ok(bytesReceived: newStart);
      }

      attempt++;
      if (attempt > maxRetries) return resp;
      await Future<void>.delayed(
        _kRetryBackoffs[(attempt - 1).clamp(0, _kRetryBackoffs.length - 1)],
      );
    }
  }

  Future<_ChunkResult> _sendOneChunk({
    required http.Client client,
    required String serverUrl,
    required String uploadId,
    required List<int> chunk,
    required int start,
    required int total,
  }) async {
    final end = start + chunk.length - 1;
    final resp = await _authedRequest(
      build: (token) =>
          http.Request(
              'PATCH',
              Uri.parse('$serverUrl/api/media/upload/$uploadId/chunk'),
            )
            ..headers['Authorization'] = 'Bearer $token'
            ..headers[_kContentType] = _kOctetStream
            ..headers['Content-Range'] = 'bytes $start-$end/$total'
            ..bodyBytes = chunk,
      client: client,
    );

    final text = await resp.stream.bytesToString();
    if (resp.statusCode == 200) {
      final data = jsonDecode(text) as Map<String, dynamic>;
      return _ChunkResult.ok(
        bytesReceived: (data['bytes_received'] as num).toInt(),
      );
    }

    if (resp.statusCode == 416) {
      // Body shape mirrors the server-side `range_mismatch` AppError:
      // `{ "bytes_received": N }`.  Defensive parse so a future body
      // shape change doesn't crash the client.
      var rebased = -1;
      try {
        final data = jsonDecode(text) as Map<String, dynamic>;
        final raw = data['bytes_received'];
        if (raw is num) rebased = raw.toInt();
      } catch (_) {
        // Older servers may return an empty 416 body.  Trigger a state
        // fetch as a fallback.
      }
      if (rebased < 0) {
        rebased =
            await _getState(
              client: client,
              serverUrl: serverUrl,
              uploadId: uploadId,
            ) ??
            -1;
      }
      return _ChunkResult.fail(
        statusCode: 416,
        errorMessage: _extractError(text),
        bytesReceived: rebased,
      );
    }

    return _ChunkResult.fail(
      statusCode: resp.statusCode,
      errorMessage: _extractError(text),
    );
  }

  Future<int?> _getState({
    required http.Client client,
    required String serverUrl,
    required String uploadId,
  }) async {
    final resp = await _authedRequest(
      build: (token) => http.Request(
        'GET',
        Uri.parse('$serverUrl/api/media/upload/$uploadId'),
      )..headers['Authorization'] = 'Bearer $token',
      client: client,
    );
    final text = await resp.stream.bytesToString();
    if (resp.statusCode != 200) return null;
    try {
      final data = jsonDecode(text) as Map<String, dynamic>;
      final raw = data['bytes_received'];
      return raw is num ? raw.toInt() : null;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Step 3: finalize
  // ---------------------------------------------------------------------------

  Future<ChunkedUploadResult> _finalize({
    required http.Client client,
    required String serverUrl,
    required String uploadId,
  }) async {
    final resp = await _authedRequest(
      build: (token) =>
          http.Request(
              'POST',
              Uri.parse('$serverUrl/api/media/upload/$uploadId/finalize'),
            )
            ..headers['Authorization'] = 'Bearer $token'
            ..headers[_kContentType] = _kJsonMime
            ..body = '{}',
      client: client,
    );
    final text = await resp.stream.bytesToString();
    if (resp.statusCode != 201 && resp.statusCode != 200) {
      return ChunkedUploadResult(
        ok: false,
        statusCode: resp.statusCode,
        errorMessage: _extractError(text),
      );
    }
    try {
      final data = jsonDecode(text) as Map<String, dynamic>;
      return ChunkedUploadResult(
        ok: true,
        statusCode: resp.statusCode,
        url: data['url'] as String?,
        width: data['width'] as int?,
        height: data['height'] as int?,
      );
    } catch (_) {
      return ChunkedUploadResult(
        ok: false,
        statusCode: resp.statusCode,
        errorMessage: 'Malformed finalize response',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Shared helpers
  // ---------------------------------------------------------------------------

  /// Send `build(token)` and, if the response is a 401, run `_refresher`
  /// once and retry exactly once with the new token.
  Future<http.StreamedResponse> _authedRequest({
    required http.Request Function(String token) build,
    required http.Client client,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = _tokenGetter() ?? '';
      final resp = await client.send(build(token));
      if (resp.statusCode == 401 && attempt == 0) {
        // Drain the body so the connection can be returned to the pool.
        await resp.stream.drain<void>();
        final refreshed = await _refresher();
        if (!refreshed) return resp;
        continue;
      }
      return resp;
    }
    throw StateError('unreachable: _authedRequest loop exited');
  }

  Future<List<int>> _readSlice(File file, int start, int end) async {
    // openRead is a `Stream<List<int>>` that lazily reads only the
    // requested byte window from disk, so we never load the whole file
    // into RAM even for multi-GB inputs.
    final out = <int>[];
    await for (final chunk in file.openRead(start, end)) {
      out.addAll(chunk);
    }
    return out;
  }

  /// Best-effort extraction of a server-side error string.
  static String? _extractError(String body) {
    if (body.isEmpty) return null;
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      return (data['error'] ?? data['message']) as String?;
    } catch (_) {
      return body.length > 200 ? body.substring(0, 200) : body;
    }
  }
}

// ---------------------------------------------------------------------------
// Internal result types
// ---------------------------------------------------------------------------

class _InitResult {
  _InitResult.ok({required this.uploadId, required this.chunkSize})
    : ok = true,
      statusCode = 201,
      errorMessage = null;
  _InitResult.fail({required this.statusCode, this.errorMessage})
    : ok = false,
      uploadId = '',
      chunkSize = 0;

  final bool ok;
  final String uploadId;
  final int chunkSize;
  final int? statusCode;
  final String? errorMessage;
}

class _ChunkResult {
  _ChunkResult.ok({required this.bytesReceived})
    : ok = true,
      statusCode = 200,
      errorMessage = null;
  _ChunkResult.fail({
    required this.statusCode,
    this.errorMessage,
    this.bytesReceived = -1,
  }) : ok = false;

  final bool ok;
  final int bytesReceived;
  final int? statusCode;
  final String? errorMessage;
}
