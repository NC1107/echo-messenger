import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../providers/auth_provider.dart';
import '../../providers/channels_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/crypto_provider.dart';
import '../../services/toast_service.dart';
import '../chat_panel_controller.dart';

/// History-loading helpers extracted from `_ChatPanelState` (#512 slice 6).
///
/// These mirror the original Riverpod-driven `_loadHistory`,
/// `_loadOlderMessages`, `_jumpToReplyQuote`, and `_loadChannels` methods
/// bit-for-bit. The `#prod-2026-05-08` pagination cursor rationale lives on
/// [ChatPanelController.paginationCursor]; the comment threads through
/// both pagination sites.

Future<void> loadHistory({
  required WidgetRef ref,
  required Conversation conv,
  required String? selectedTextChannelId,
}) async {
  final auth = ref.read(authProvider);
  if (auth.token == null || auth.userId == null) return;

  // Load cached messages first for instant display
  ref.read(chatProvider.notifier).loadFromCache(conv.id, auth.userId!);

  final groupCrypto = conv.isGroup
      ? ref.read(groupCryptoServiceProvider)
      : null;
  if (groupCrypto != null) {
    groupCrypto.setToken(auth.token!);
  }

  // For 1:1 DMs, pass the crypto service so encrypted messages can be
  // decrypted. Without this, _decryptIfNeeded sees crypto==null and
  // shows "[Encrypted history]" instead of the actual message content.
  final cryptoState = ref.read(cryptoProvider);
  final crypto = (!conv.isGroup && cryptoState.isInitialized)
      ? ref.read(cryptoServiceProvider)
      : null;
  if (crypto != null) {
    crypto.setToken(auth.token!);
  }

  await ref
      .read(chatProvider.notifier)
      .loadHistoryWithUserId(
        conv.id,
        auth.token!,
        auth.userId!,
        channelId: selectedTextChannelId,
        crypto: crypto,
        isGroup: conv.isGroup,
        groupCrypto: groupCrypto,
      );
}

void loadChannels({required WidgetRef ref, required Conversation conv}) {
  ref.read(channelsProvider.notifier).loadChannels(conv.id);
}

void loadOlderMessages({
  required WidgetRef ref,
  required Conversation conv,
  required String? selectedTextChannelId,
  required ChatPanelController controller,
}) {
  final chatState = ref.read(chatProvider);
  // Use the channel-aware helpers — the underlying maps key by
  // `conversationId:channelId` (or `conversationId:` for the unchanneled
  // group root), so a raw lookup by `conv.id` always missed in
  // channelized groups, hiding active history loads and triggering
  // duplicate paginate requests (#510).
  if (chatState.isLoadingHistory(conv.id, channelId: selectedTextChannelId) ||
      !chatState.conversationHasMore(
        conv.id,
        channelId: selectedTextChannelId,
      )) {
    return;
  }

  final messages = conv.isGroup
      ? chatState.messagesForConversationChannel(
          conv.id,
          channelId: selectedTextChannelId,
          includeUnchanneled: selectedTextChannelId == null,
        )
      : chatState.messagesForConversation(conv.id);
  if (messages.isEmpty) return;

  // Use the oldest channel-scoped non-system message as the pagination
  // cursor — see `ChatPanelController.paginationCursor` for the
  // `#prod-2026-05-08` rationale.
  final oldestTimestamp = controller.paginationCursor(messages).timestamp;
  final auth = ref.read(authProvider);
  if (auth.token == null || auth.userId == null) return;

  final groupCryptoOlder = conv.isGroup
      ? ref.read(groupCryptoServiceProvider)
      : null;
  if (groupCryptoOlder != null) {
    groupCryptoOlder.setToken(auth.token!);
  }

  // Pass crypto for 1:1 DM decryption (same as loadHistory)
  final cryptoStateOlder = ref.read(cryptoProvider);
  final cryptoOlder = (!conv.isGroup && cryptoStateOlder.isInitialized)
      ? ref.read(cryptoServiceProvider)
      : null;
  if (cryptoOlder != null) {
    cryptoOlder.setToken(auth.token!);
  }

  ref
      .read(chatProvider.notifier)
      .loadHistoryWithUserId(
        conv.id,
        auth.token!,
        auth.userId!,
        channelId: selectedTextChannelId,
        before: oldestTimestamp,
        crypto: cryptoOlder,
        isGroup: conv.isGroup,
        groupCrypto: groupCryptoOlder,
      );
}

Future<void> jumpToReplyQuote({
  required BuildContext context,
  required WidgetRef ref,
  required Conversation conv,
  required String? selectedTextChannelId,
  required ChatPanelController controller,
  required String replyToId,
  required List<ChatMessage> Function(Conversation, ChatState, String?, bool)
  resolveMessages,
  required bool Function() mounted,
  required VoidCallback onHighlight,
}) async {
  final selectedChannelId = conv.isGroup ? selectedTextChannelId : null;
  final includeUnchanneled = conv.isGroup && selectedTextChannelId == null;

  bool isLoaded() {
    final state = ref.read(chatProvider);
    final loaded = resolveMessages(
      conv,
      state,
      selectedChannelId,
      includeUnchanneled,
    );
    return loaded.indexWhere((m) => m.id == replyToId) >= 0;
  }

  // Fast path: already in memory.
  if (isLoaded()) {
    onHighlight();
    return;
  }

  // Slow path: paginate older history until the target appears or
  // `hasMore` flips to false.  Cap to 30 rounds (~1500 msgs at 50/round)
  // so a stale or removed parent can't spin forever.
  final auth = ref.read(authProvider);
  if (auth.token == null || auth.userId == null) return;

  final groupCrypto = conv.isGroup
      ? ref.read(groupCryptoServiceProvider)
      : null;
  groupCrypto?.setToken(auth.token!);

  final cryptoState = ref.read(cryptoProvider);
  final crypto = (!conv.isGroup && cryptoState.isInitialized)
      ? ref.read(cryptoServiceProvider)
      : null;
  crypto?.setToken(auth.token!);

  for (var round = 0; round < 30; round++) {
    if (!mounted()) return;
    final state = ref.read(chatProvider);
    if (!state.conversationHasMore(conv.id, channelId: selectedTextChannelId)) {
      break;
    }
    final loaded = resolveMessages(
      conv,
      state,
      selectedChannelId,
      includeUnchanneled,
    );
    if (loaded.isEmpty) break;
    // Use the oldest channel-scoped (non-system) message as the
    // pagination cursor — see `ChatPanelController.paginationCursor` for
    // the `#prod-2026-05-08` rationale.
    final cursor = controller.paginationCursor(loaded);

    await ref
        .read(chatProvider.notifier)
        .loadHistoryWithUserId(
          conv.id,
          auth.token!,
          auth.userId!,
          channelId: selectedTextChannelId,
          before: cursor.timestamp,
          crypto: crypto,
          isGroup: conv.isGroup,
          groupCrypto: groupCrypto,
        );
    if (!mounted()) return;
    if (isLoaded()) {
      onHighlight();
      return;
    }
  }

  if (!context.mounted) return;
  ToastService.show(
    context,
    'Original message not available',
    type: ToastType.info,
  );
}
