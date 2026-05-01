import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../providers/auth_provider.dart';

/// Result returned by [UploadClient.uploadFile].
class UploadResult {
  const UploadResult({
    required this.ok,
    this.url,
    this.errorMessage,
    this.errorCode,
    this.statusCode,
  });

  /// True when the server returned 2xx and the upload succeeded.
  final bool ok;

  /// The URL of the uploaded resource, if the server returned one.
  final String? url;

  /// Human-readable error message extracted from the JSON body, if any.
  final String? errorMessage;

  /// Machine-readable error code from the server (e.g. "token-expired").
  final String? errorCode;

  /// Raw HTTP status code.
  final int? statusCode;

  @override
  String toString() =>
      'UploadResult(ok: $ok, url: $url, status: $statusCode, '
      'error: $errorMessage, code: $errorCode)';
}

/// Shared multipart upload helper used by every upload surface in the client.
///
/// Handles:
/// - Injecting the `Authorization: Bearer <token>` header.
/// - One automatic 401 → refresh → retry cycle via [AuthNotifier.refreshAccessToken].
/// - Unified JSON error parsing including the `code` discriminant from #633.
/// - Optional extra form fields (e.g. `conversation_id`).
/// - Optional progress reporting via a chunked stream when [onProgress] is set.
///
/// The on-the-wire request format is unchanged from the original per-site code;
/// only the shared plumbing moves here.
///
/// ## Testability
///
/// Use [UploadClient.withCallbacks] in unit tests to inject stub token/refresh
/// callbacks without requiring a live [AuthNotifier] or Riverpod container.
class UploadClient {
  /// Construct from a live [AuthNotifier] (production use).
  UploadClient(AuthNotifier auth)
    : _tokenGetter = (() => auth.currentToken),
      _refresher = auth.refreshAccessToken;

  /// Construct from bare callbacks (unit tests and fakes).
  UploadClient.withCallbacks({
    required String? Function() tokenGetter,
    required Future<bool> Function() refresher,
  }) : _tokenGetter = tokenGetter,
       _refresher = refresher;

  final String? Function() _tokenGetter;
  final Future<bool> Function() _refresher;

  static const _kChunkSize = 64 * 1024;

  /// Upload [bytes] to [path] under a multipart field named [fieldName].
  ///
  /// [method] defaults to `POST`; pass `PUT` for avatar endpoints.
  /// [extraFields] are added as plain form fields before the file part.
  /// [onProgress] receives `(sent, total)` byte counts during streaming.
  Future<UploadResult> uploadFile({
    required String serverUrl,
    required String path,
    required List<int> bytes,
    required String fileName,
    required String mimeType,
    String method = 'POST',
    String fieldName = 'file',
    Map<String, String>? extraFields,
    void Function(int sent, int total)? onProgress,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = _tokenGetter();
      if (token == null) {
        return const UploadResult(ok: false, errorMessage: 'Not authenticated');
      }

      final request = _buildRequest(
        method: method,
        uri: Uri.parse('$serverUrl$path'),
        token: token,
        bytes: bytes,
        fileName: fileName,
        mimeType: mimeType,
        fieldName: fieldName,
        extraFields: extraFields,
        onProgress: onProgress,
      );

      final streamed = await request.send();
      final body = await streamed.stream.bytesToString();
      final status = streamed.statusCode;

      if (status == 401 && attempt == 0) {
        final refreshed = await _refresher();
        if (!refreshed) {
          return const UploadResult(
            ok: false,
            statusCode: 401,
            errorMessage: 'Session expired',
            errorCode: 'token-expired',
          );
        }
        continue;
      }

      if (status == 200 || status == 201) {
        final url = _parseUrl(body);
        return UploadResult(ok: true, url: url, statusCode: status);
      }

      final (msg, code) = _parseError(body);
      return UploadResult(
        ok: false,
        statusCode: status,
        errorMessage: msg,
        errorCode: code,
      );
    }

    // Should not be reached.
    return const UploadResult(ok: false, errorMessage: 'Upload failed');
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  http.MultipartRequest _buildRequest({
    required String method,
    required Uri uri,
    required String token,
    required List<int> bytes,
    required String fileName,
    required String mimeType,
    required String fieldName,
    Map<String, String>? extraFields,
    void Function(int sent, int total)? onProgress,
  }) {
    final request = http.MultipartRequest(method, uri);
    request.headers['Authorization'] = 'Bearer $token';

    if (extraFields != null) {
      request.fields.addAll(extraFields);
    }

    final parts = mimeType.split('/');
    final mediaType = parts.length == 2
        ? MediaType(parts[0], parts[1])
        : MediaType('application', 'octet-stream');

    if (onProgress == null) {
      request.files.add(
        http.MultipartFile.fromBytes(
          fieldName,
          bytes,
          filename: fileName,
          contentType: mediaType,
        ),
      );
    } else {
      final total = bytes.length;
      Stream<List<int>> chunked() async* {
        var offset = 0;
        while (offset < total) {
          final end = (offset + _kChunkSize).clamp(0, total);
          yield bytes.sublist(offset, end);
          offset = end;
          onProgress(offset, total);
        }
      }

      request.files.add(
        http.MultipartFile(
          fieldName,
          chunked(),
          total,
          filename: fileName,
          contentType: mediaType,
        ),
      );
    }

    return request;
  }

  /// Extracts `url` or `avatar_url` from a 2xx JSON body.
  String? _parseUrl(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      return (data['url'] ?? data['avatar_url']) as String?;
    } catch (_) {
      return null;
    }
  }

  /// Returns `(errorMessage, errorCode)` from a non-2xx JSON body.
  (String?, String?) _parseError(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final msg = data['error'] as String?;
      final code = data['code'] as String?;
      return (msg, code);
    } catch (_) {
      return (null, null);
    }
  }
}
