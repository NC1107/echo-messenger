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

/// `#prod-2026-05-08` pagination cursor rationale lives on
/// [ChatPanelController.paginationCursor].

/// Auth + crypto bundle resolved for a single history call. Returns `null`
/// when the user isn't authenticated; otherwise [groupCrypto] is populated
/// for group convs and [crypto] for 1:1 DMs (when crypto is initialized).
/// Both [setToken] calls are made before the bundle is returned.
class _HistoryAuth {
  _HistoryAuth({
    required this.token,
    required this.userId,
    required this.crypto,
    required this.groupCrypto,
  });
  final String token;
  final String userId;
  final dynamic crypto;
  final dynamic groupCrypto;
}

_HistoryAuth? _resolveAuth(WidgetRef ref, Conversation conv) {
  final auth = ref.read(authProvider);
  final token = auth.token;
  final userId = auth.userId;
  if (token == null || userId == null) return null;

  final groupCrypto = conv.isGroup
      ? ref.read(groupCryptoServiceProvider)
      : null;
  groupCrypto?.setToken(token);

  // For 1:1 DMs, pass the crypto service so encrypted messages can be
  // decrypted. Without this, `_decryptIfNeeded` sees crypto==null and
  // shows "[Encrypted history]" instead of the actual message content.
  final cryptoState = ref.read(cryptoProvider);
  final crypto = (!conv.isGroup && cryptoState.isInitialized)
      ? ref.read(cryptoServiceProvider)
      : null;
  crypto?.setToken(token);

  return _HistoryAuth(
    token: token,
    userId: userId,
    crypto: crypto,
    groupCrypto: groupCrypto,
  );
}

Future<void> loadHistory({
  required WidgetRef ref,
  required Conversation conv,
  required String? selectedTextChannelId,
}) async {
  final a = _resolveAuth(ref, conv);
  if (a == null) return;

  // Load cached messages first for instant display
  ref.read(chatProvider.notifier).loadFromCache(conv.id, a.userId);

  await ref
      .read(chatProvider.notifier)
      .loadHistoryWithUserId(
        conv.id,
        a.token,
        a.userId,
        channelId: selectedTextChannelId,
        crypto: a.crypto,
        isGroup: conv.isGroup,
        groupCrypto: a.groupCrypto,
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
  final a = _resolveAuth(ref, conv);
  if (a == null) return;

  ref
      .read(chatProvider.notifier)
      .loadHistoryWithUserId(
        conv.id,
        a.token,
        a.userId,
        channelId: selectedTextChannelId,
        before: oldestTimestamp,
        crypto: a.crypto,
        isGroup: conv.isGroup,
        groupCrypto: a.groupCrypto,
      );
}

bool _isReplyLoaded(
  WidgetRef ref,
  Conversation conv,
  String? selectedChannelId,
  bool includeUnchanneled,
  String replyToId,
  List<ChatMessage> Function(Conversation, ChatState, String?, bool)
  resolveMessages,
) {
  final state = ref.read(chatProvider);
  final loaded = resolveMessages(
    conv,
    state,
    selectedChannelId,
    includeUnchanneled,
  );
  return loaded.indexWhere((m) => m.id == replyToId) >= 0;
}

Future<bool> _paginateOnceForReply(
  WidgetRef ref,
  Conversation conv,
  String? selectedTextChannelId,
  String? selectedChannelId,
  bool includeUnchanneled,
  String replyToId,
  ChatPanelController controller,
  _HistoryAuth a,
  bool Function() mounted,
  List<ChatMessage> Function(Conversation, ChatState, String?, bool)
  resolveMessages,
) async {
  if (!mounted()) return false;
  final state = ref.read(chatProvider);
  if (!state.conversationHasMore(conv.id, channelId: selectedTextChannelId)) {
    return false;
  }
  final loaded = resolveMessages(
    conv,
    state,
    selectedChannelId,
    includeUnchanneled,
  );
  if (loaded.isEmpty) return false;

  final cursor = controller.paginationCursor(loaded);
  await ref
      .read(chatProvider.notifier)
      .loadHistoryWithUserId(
        conv.id,
        a.token,
        a.userId,
        channelId: selectedTextChannelId,
        before: cursor.timestamp,
        crypto: a.crypto,
        isGroup: conv.isGroup,
        groupCrypto: a.groupCrypto,
      );

  if (!mounted()) return false;
  return _isReplyLoaded(
    ref,
    conv,
    selectedChannelId,
    includeUnchanneled,
    replyToId,
    resolveMessages,
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

  // Fast path: already in memory.
  if (_isReplyLoaded(
    ref,
    conv,
    selectedChannelId,
    includeUnchanneled,
    replyToId,
    resolveMessages,
  )) {
    onHighlight();
    return;
  }

  // Slow path: paginate older history until the target appears or
  // `hasMore` flips to false.  Cap to 30 rounds (~1500 msgs at 50/round)
  // so a stale or removed parent can't spin forever.
  final a = _resolveAuth(ref, conv);
  if (a == null) return;

  // Cap loop to 30 rounds (~1500 msgs at 50/round)
  var round = 0;
  while (round < 30) {
    round++;
    final found = await _paginateOnceForReply(
      ref,
      conv,
      selectedTextChannelId,
      selectedChannelId,
      includeUnchanneled,
      replyToId,
      controller,
      a,
      mounted,
      resolveMessages,
    );
    if (!found) break;
    onHighlight();
    return;
  }

  if (!context.mounted) return;
  ToastService.show(
    context,
    'Original message not available',
    type: ToastType.info,
  );
}
