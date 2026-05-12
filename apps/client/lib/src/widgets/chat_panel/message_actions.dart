import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../models/reaction.dart';
import '../../providers/auth_provider.dart';
import '../../providers/channels_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/media_ticket_provider.dart';
import '../../providers/server_url_provider.dart';
import '../../providers/websocket_provider.dart';
import '../../services/message_cache.dart';
import '../../services/saved_messages_service.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';
import '../forward_message_dialog.dart';
import '../image_gallery_viewer.dart';
import '../message/media_content.dart'
    show
        extractEmbeddedImageUrls,
        isImageUrl,
        isStandaloneMediaUrl,
        mediaHeaders,
        resolveMediaUrl;
import 'full_reaction_picker.dart';

/// Top-level message-action helpers extracted from the `_ChatPanelState`
/// god-module (#512 slice 6). Each function takes `(WidgetRef ref,
/// BuildContext context, ...)` so the call sites on `_ChatPanelState`
/// reduce to one-line forwarders.
///
/// These mirror the original methods bit-for-bit — no behavior changes.
/// Lifecycle checks use `context.mounted` so the analyzer's
/// `use_build_context_synchronously` lint stays clean across async gaps.

enum DeleteChoice { forMe, forEveryone }

Future<void> retryMessage({
  required WidgetRef ref,
  required Conversation conv,
  required ChatMessage message,
}) async {
  final chatNotifier = ref.read(chatProvider.notifier);
  chatNotifier.updateMessageStatus(conv.id, message.id, MessageStatus.sending);
  try {
    final ws = ref.read(websocketProvider.notifier);
    if (conv.isGroup) {
      await ws.sendGroupMessage(
        conv.id,
        message.failedContent ?? message.content,
        channelId: message.channelId,
        replyToId: message.replyToId,
      );
    } else {
      final myUserId = ref.read(authProvider).userId ?? '';
      final peer = conv.members.where((m) => m.userId != myUserId).firstOrNull;
      if (peer == null) return;
      await ws.sendMessage(
        peer.userId,
        message.failedContent ?? message.content,
        conversationId: conv.id,
        replyToId: message.replyToId,
      );
    }
  } catch (_) {
    ref
        .read(chatProvider.notifier)
        .updateMessageStatus(conv.id, message.id, MessageStatus.failed);
  }
}

void deleteFailed({
  required WidgetRef ref,
  required Conversation conv,
  required ChatMessage message,
}) {
  ref.read(chatProvider.notifier).deleteMessage(conv.id, message.id);
}

void forwardMessage({
  required BuildContext context,
  required WidgetRef ref,
  required ChatMessage message,
}) {
  showForwardDialog(
    context: context,
    onForward: (target) => sendForwardedMessage(ref, context, message, target),
  );
}

Future<void> sendForwardedMessage(
  WidgetRef ref,
  BuildContext context,
  ChatMessage message,
  Conversation target,
) async {
  final myUserId = ref.read(authProvider).userId ?? '';
  final ws = ref.read(websocketProvider.notifier);
  final content = message.content;

  try {
    await ref.read(chatProvider.notifier).forwardMessage(content, target.id, (
      forwardedContent,
    ) async {
      // Add optimistic message so the sender sees it locally immediately.
      String peerUserId = '';
      String? channelId;
      if (!target.isGroup) {
        final peer = target.members
            .where((m) => m.userId != myUserId)
            .firstOrNull;
        peerUserId = peer?.userId ?? '';
      } else {
        // Look up the default text channel so the optimistic message has the
        // same channelId that the server will return in message_sent.
        // Without this, _replacePendingMessage's channelId filter never
        // matches and the pending message times out to failed.
        final channels = ref.read(channelsProvider).channelsFor(target.id);
        channelId = channels.where((c) => c.isText).firstOrNull?.id;
      }
      ref
          .read(chatProvider.notifier)
          .addOptimistic(
            peerUserId,
            forwardedContent,
            myUserId,
            conversationId: target.id,
            channelId: channelId,
          );

      if (target.isGroup) {
        await ws.sendGroupMessage(
          target.id,
          forwardedContent,
          channelId: channelId,
        );
      } else {
        final peer = target.members
            .where((m) => m.userId != myUserId)
            .firstOrNull;
        if (peer == null) return;
        await ws.sendMessage(
          peer.userId,
          forwardedContent,
          conversationId: target.id,
        );
      }
    });

    if (context.mounted) {
      ToastService.show(context, 'Message forwarded', type: ToastType.success);
    }
  } catch (e) {
    if (context.mounted) {
      ToastService.show(
        context,
        'Failed to forward message',
        type: ToastType.error,
      );
    }
  }
}

void confirmDelete({
  required BuildContext context,
  required WidgetRef ref,
  required Conversation conv,
  required ChatMessage message,
  required Future<void> Function(String) addToDeletedForMe,
}) {
  showDialog<DeleteChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: context.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: context.border),
      ),
      title: const Text('Delete message?'),
      actions: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, DeleteChoice.forMe),
              child: Text(
                'Delete for me',
                style: TextStyle(color: context.textSecondary),
              ),
            ),
            if (message.isMine)
              TextButton(
                onPressed: () => Navigator.pop(ctx, DeleteChoice.forEveryone),
                child: const Text(
                  'Delete for everyone',
                  style: TextStyle(color: EchoTheme.danger),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'Cancel',
                style: TextStyle(color: context.textSecondary),
              ),
            ),
          ],
        ),
      ],
    ),
  ).then((choice) async {
    if (choice == null) return;
    if (choice == DeleteChoice.forMe) {
      ref.read(chatProvider.notifier).deleteMessage(conv.id, message.id);
      MessageCache.removeMessage(conv.id, message.id);
      await addToDeletedForMe(message.id);
      if (context.mounted) {
        ToastService.show(
          context,
          'Message deleted for you',
          type: ToastType.info,
        );
      }
    } else {
      if (!context.mounted) return;
      await deleteForEveryone(ref, context, conv.id, message);
    }
  });
}

/// Delete a message for every recipient. Optimistically removes it from
/// local state for a responsive UI, awaits the server DELETE, and rolls
/// the message back into local state if the request fails (auth expired,
/// network drop, server error). Without the await/rollback the user was
/// being told the message had been deleted "for everyone" even when only
/// local state changed (#511).
Future<void> deleteForEveryone(
  WidgetRef ref,
  BuildContext context,
  String conversationId,
  ChatMessage message,
) async {
  ref.read(chatProvider.notifier).deleteMessage(conversationId, message.id);

  final serverUrl = ref.read(serverUrlProvider);
  http.Response? response;
  Object? networkError;
  try {
    response = await ref
        .read(authProvider.notifier)
        .authenticatedRequest(
          (token) => http.delete(
            Uri.parse('$serverUrl/api/messages/${message.id}'),
            headers: {'Authorization': 'Bearer $token'},
          ),
        );
  } catch (e) {
    networkError = e;
  }

  if (!context.mounted) return;

  final ok =
      response != null &&
      response.statusCode >= 200 &&
      response.statusCode < 300;
  if (ok) {
    ToastService.show(
      context,
      'Message deleted for everyone',
      type: ToastType.success,
    );
  } else {
    // Rollback: re-insert the message so the user sees their content
    // wasn't actually removed remotely.
    ref.read(chatProvider.notifier).addMessage(message);
    final reason = networkError != null
        ? 'Network error'
        : 'Server returned ${response!.statusCode}';
    ToastService.show(
      context,
      'Failed to delete: $reason',
      type: ToastType.error,
    );
  }
}

Future<void> pinMessage({
  required BuildContext context,
  required WidgetRef ref,
  required Conversation conv,
  required ChatMessage message,
}) async {
  final myUserId = ref.read(authProvider).userId ?? '';
  final serverUrl = ref.read(serverUrlProvider);

  // Optimistically update local state
  ref
      .read(chatProvider.notifier)
      .updateMessagePin(conv.id, message.id, myUserId, DateTime.now());

  try {
    final response = await ref
        .read(authProvider.notifier)
        .authenticatedRequest(
          (token) => http.post(
            Uri.parse(
              '$serverUrl/api/conversations/${conv.id}'
              '/messages/${message.id}/pin',
            ),
            headers: {'Authorization': 'Bearer $token'},
          ),
        );
    if (!context.mounted) return;
    if (response.statusCode >= 200 && response.statusCode < 300) {
      ToastService.show(context, 'Message pinned', type: ToastType.success);
    } else {
      // Revert on failure
      ref
          .read(chatProvider.notifier)
          .updateMessagePin(conv.id, message.id, null, null);
      ToastService.show(
        context,
        'Failed to pin message',
        type: ToastType.error,
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    ref
        .read(chatProvider.notifier)
        .updateMessagePin(conv.id, message.id, null, null);
    ToastService.show(context, 'Failed to pin message', type: ToastType.error);
  }
}

Future<void> unpinMessage({
  required BuildContext context,
  required WidgetRef ref,
  required Conversation conv,
  required ChatMessage message,
}) async {
  final serverUrl = ref.read(serverUrlProvider);

  // Save previous state for revert
  final prevPinnedById = message.pinnedById;
  final prevPinnedAt = message.pinnedAt;

  // Optimistically clear pin
  ref
      .read(chatProvider.notifier)
      .updateMessagePin(conv.id, message.id, null, null);

  try {
    final response = await ref
        .read(authProvider.notifier)
        .authenticatedRequest(
          (token) => http.delete(
            Uri.parse(
              '$serverUrl/api/conversations/${conv.id}'
              '/messages/${message.id}/pin',
            ),
            headers: {'Authorization': 'Bearer $token'},
          ),
        );
    if (!context.mounted) return;
    if (response.statusCode >= 200 && response.statusCode < 300) {
      ToastService.show(context, 'Message unpinned', type: ToastType.success);
    } else {
      // Revert on failure
      ref
          .read(chatProvider.notifier)
          .updateMessagePin(conv.id, message.id, prevPinnedById, prevPinnedAt);
      ToastService.show(
        context,
        'Failed to unpin message',
        type: ToastType.error,
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    ref
        .read(chatProvider.notifier)
        .updateMessagePin(conv.id, message.id, prevPinnedById, prevPinnedAt);
    ToastService.show(
      context,
      'Failed to unpin message',
      type: ToastType.error,
    );
  }
}

Future<void> saveMessage({
  required BuildContext context,
  required ChatMessage message,
  required void Function(String) onAddSavedId,
}) async {
  await SavedMessagesService.instance.bookmark(message);
  if (!context.mounted) return;
  onAddSavedId(message.id);
  ToastService.show(context, 'Message saved', type: ToastType.success);
}

Future<void> unsaveMessage({
  required BuildContext context,
  required ChatMessage message,
  required void Function(String) onRemoveSavedId,
}) async {
  await SavedMessagesService.instance.unsaveMessage(message.id);
  if (!context.mounted) return;
  onRemoveSavedId(message.id);
  ToastService.show(context, 'Bookmark removed', type: ToastType.info);
}

void toggleReaction({
  required WidgetRef ref,
  required Conversation conv,
  required ChatMessage message,
  required String emoji,
  required bool remove,
}) {
  // Guard: the message may have been deleted via WebSocket between the
  // time the user opened the reaction picker and tapped an emoji.
  final stillExists = ref
      .read(chatProvider)
      .messagesForConversation(conv.id)
      .any((m) => m.id == message.id);
  if (!stillExists) return;

  final myUserId = ref.read(authProvider).userId ?? '';
  ref.read(websocketProvider.notifier).sendReaction(conv.id, message.id, emoji);
  if (remove) {
    ref
        .read(chatProvider.notifier)
        .removeReaction(conv.id, message.id, myUserId, emoji);
  } else {
    ref
        .read(chatProvider.notifier)
        .addReaction(
          conv.id,
          Reaction(
            messageId: message.id,
            userId: myUserId,
            username: '',
            emoji: emoji,
          ),
        );
  }
}

void showFullReactionPickerFor({
  required BuildContext context,
  required ChatMessage message,
  required String myUserId,
  required void Function(String emoji, bool alreadyReacted) onPick,
}) {
  showFullReactionPicker(
    context,
    message: message,
    myUserId: myUserId,
    onPick: onPick,
  );
}

/// Collects all resolved image URLs from [messages] in order, then opens the
/// gallery viewer starting at the image matching [tappedUrl].
void openImageGallery({
  required BuildContext context,
  required WidgetRef ref,
  required String tappedUrl,
  required List<ChatMessage> messages,
  required String serverUrl,
  required String authToken,
}) {
  final headers = mediaHeaders(authToken: authToken);
  final mediaTicket = ref.read(mediaTicketProvider);

  // Build an ordered list of all image URLs from this message list.
  final allUrls = <String>[];
  for (final msg in messages) {
    // [img:URL] marker — single image message.
    final imgMatch = RegExp(r'^\[img:(.+)\]$').firstMatch(msg.content);
    if (imgMatch != null) {
      final raw = imgMatch.group(1)!;
      allUrls.add(
        resolveMediaUrl(
          raw,
          serverUrl: serverUrl,
          authToken: authToken,
          mediaTicket: mediaTicket,
        ),
      );
      continue;
    }

    // Standalone image URL (e.g. https://…/photo.png).
    if (isStandaloneMediaUrl(msg.content) && isImageUrl(msg.content.trim())) {
      allUrls.add(
        resolveMediaUrl(
          msg.content.trim(),
          serverUrl: serverUrl,
          authToken: authToken,
          mediaTicket: mediaTicket,
        ),
      );
      continue;
    }

    // Embedded image URLs mixed into text.
    for (final embUrl in extractEmbeddedImageUrls(msg.content)) {
      allUrls.add(embUrl);
    }
  }

  if (allUrls.isEmpty) {
    // Fallback: show only the tapped image.
    allUrls.add(tappedUrl);
  }

  // Find the index of the tapped URL. Use string-starts-with matching to
  // handle minor URL differences (e.g. trailing query params differ).
  final idx = allUrls.indexWhere(
    (u) => u == tappedUrl || u.startsWith(tappedUrl) || tappedUrl.startsWith(u),
  );

  showImageGallery(
    context: context,
    imageUrls: allUrls,
    initialIndex: idx < 0 ? 0 : idx,
    headers: headers,
  );
}

String fullMonthName(int m) {
  const names = [
    '',
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return names[m.clamp(1, 12)];
}
