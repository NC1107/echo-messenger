import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import 'message_cache.dart';

/// Exports the user's locally-cached (decrypted) messages to a JSON file.
///
/// Only fields safe for export are included (message content + metadata).
/// Private keys and Signal session state are never exported.
///
/// The caller supplies [userId] and [username] from the auth provider so the
/// export can be scoped correctly. [conversationNames] is an optional map of
/// conversation ID → display name; unknown IDs fall back to the raw ID.
class ExportService {
  ExportService._();

  static const int _exportVersion = 1;

  /// Build the export payload and trigger a platform save-file dialog.
  ///
  /// Returns the path chosen by the user, or null if they cancelled.
  /// Throws on unexpected errors; callers should catch and show a toast.
  static Future<String?> exportChats({
    required String userId,
    required String username,
    Map<String, String> conversationNames = const {},
  }) async {
    final payload = await buildExportPayload(
      userId: userId,
      username: username,
      conversationNames: conversationNames,
    );

    final json = const JsonEncoder.withIndent('  ').convert(payload);
    final bytes = utf8.encode(json);
    final ts = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .substring(0, 19);
    final fileName = 'echo_chat_export_$ts.json';

    return FilePicker.saveFile(
      dialogTitle: 'Save chat export',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: kIsWeb ? Uint8List.fromList(bytes) : null,
    );
  }

  /// Build the export map without touching the filesystem.
  /// Exposed for unit testing.
  static Future<Map<String, dynamic>> buildExportPayload({
    required String userId,
    required String username,
    Map<String, String> conversationNames = const {},
  }) async {
    final convIds = MessageCache.openConversationIds;
    final conversations = <Map<String, dynamic>>[];

    for (final convId in convIds) {
      final messages = await MessageCache.getCachedMessages(convId, userId);
      // Skip sentinels (undecryptable placeholders).
      final safe = messages
          .where((m) => !MessageCache.failureSentinels.contains(m.content))
          .toList();

      conversations.add({
        'conversation_id': convId,
        'name': conversationNames[convId] ?? convId,
        'messages': safe.map(_messageToExport).toList(),
      });
    }

    return {
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'version': _exportVersion,
      'user_id': userId,
      'username': username,
      'conversations': conversations,
    };
  }

  /// Strips private/sensitive fields; keeps only message content + metadata.
  static Map<String, dynamic> _messageToExport(ChatMessage m) {
    return {
      'id': m.id,
      'sender_id': m.fromUserId,
      'sender_username': m.fromUsername,
      'content': m.content,
      'created_at': m.timestamp,
      if (m.editedAt != null) 'edited_at': m.editedAt,
      if (m.replyToId != null) 'reply_to_id': m.replyToId,
      if (m.replyToContent != null) 'reply_to_content': m.replyToContent,
      if (m.replyToUsername != null) 'reply_to_username': m.replyToUsername,
      if (m.expiresAt != null) 'expires_at': m.expiresAt!.toIso8601String(),
    };
  }
}
