import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../chat_input_bar.dart';

/// Forwards files dropped onto the chat area into the input bar's
/// attachment flow, one at a time. Extracted from
/// `_ChatPanelState._onDropDone` (#512 slice 6).
Future<void> onChatPanelDropDone(
  DropDoneDetails details,
  ChatInputBarState? inputBar,
) async {
  if (details.files.isEmpty || inputBar == null) return;

  // Filter out directories before processing.
  final items = details.files.where((f) => f is! DropItemDirectory).toList();
  if (items.isEmpty) return;

  for (final item in items) {
    // On web, DropItem may carry bytes directly (no filesystem path).
    Uint8List? bytes;
    if (kIsWeb) {
      try {
        bytes = await item.readAsBytes();
      } catch (_) {}
    }

    await inputBar.attachDroppedFile(
      path: item.path,
      fileName: item.name,
      bytes: bytes,
    );
  }
}
