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

/// Parameters for a single pagination pass searching for a reply-to ancestor.
class _PaginationParams {
  _PaginationParams({
    required this.ref,
    required this.conv,
    required this.selectedTextChannelId,
    required this.selectedChannelId,
    required this.includeUnchanneled,
    required this.replyToId,
    required this.controller,
    required this.a,
    required this.mounted,
    required this.resolveMessages,
  });
  final WidgetRef ref;
  final Conversation conv;
  final String? selectedTextChannelId;
  final String? selectedChannelId;
  final bool includeUnchanneled;
  final String replyToId;
  final ChatPanelController controller;
  final _HistoryAuth a;
  final bool Function() mounted;
  final List<ChatMessage> Function(Conversation, ChatState, String?, bool)
  resolveMessages;
}

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

  // Pass crypto for 1:1 DM decrypt; without it `_decryptIfNeeded` shows "[Encrypted history]".
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
  // Channel-aware helpers (maps keyed by conv:channel) — raw conv.id lookup misses on channelized groups (#510).
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

  // Oldest channel-scoped non-system msg as cursor (see ChatPanelController.paginationCursor / #prod-2026-05-08).
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

Future<bool> _paginateOnceForReply(_PaginationParams params) async {
  if (!params.mounted()) return false;
  final state = params.ref.read(chatProvider);
  if (!state.conversationHasMore(
    params.conv.id,
    channelId: params.selectedTextChannelId,
  )) {
    return false;
  }
  final loaded = params.resolveMessages(
    params.conv,
    state,
    params.selectedChannelId,
    params.includeUnchanneled,
  );
  if (loaded.isEmpty) return false;

  final cursor = params.controller.paginationCursor(loaded);
  await params.ref
      .read(chatProvider.notifier)
      .loadHistoryWithUserId(
        params.conv.id,
        params.a.token,
        params.a.userId,
        channelId: params.selectedTextChannelId,
        before: cursor.timestamp,
        crypto: params.a.crypto,
        isGroup: params.conv.isGroup,
        groupCrypto: params.a.groupCrypto,
      );

  if (!params.mounted()) return false;
  return _isReplyLoaded(
    params.ref,
    params.conv,
    params.selectedChannelId,
    params.includeUnchanneled,
    params.replyToId,
    params.resolveMessages,
  );
}

/// Parameter bundle for [jumpToReplyQuote]. Grouped to keep the call signature
/// flat and stay under the 7-param S107 limit.
class JumpToReplyQuoteParams {
  const JumpToReplyQuoteParams({
    required this.context,
    required this.ref,
    required this.conv,
    required this.selectedTextChannelId,
    required this.controller,
    required this.replyToId,
    required this.resolveMessages,
    required this.mounted,
    required this.onHighlight,
  });

  final BuildContext context;
  final WidgetRef ref;
  final Conversation conv;
  final String? selectedTextChannelId;
  final ChatPanelController controller;
  final String replyToId;
  final List<ChatMessage> Function(Conversation, ChatState, String?, bool)
  resolveMessages;
  final bool Function() mounted;
  final VoidCallback onHighlight;
}

Future<void> jumpToReplyQuote(JumpToReplyQuoteParams params) async {
  final context = params.context;
  final ref = params.ref;
  final conv = params.conv;
  final selectedTextChannelId = params.selectedTextChannelId;
  final controller = params.controller;
  final replyToId = params.replyToId;
  final resolveMessages = params.resolveMessages;
  final mounted = params.mounted;
  final onHighlight = params.onHighlight;

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

  // Paginate older history until target or !hasMore; cap 30 rounds (~1500 msgs) so a removed parent can't spin.
  final a = _resolveAuth(ref, conv);
  if (a == null) return;

  // Cap loop to 30 rounds (~1500 msgs at 50/round)
  var round = 0;
  while (round < 30) {
    round++;
    final found = await _paginateOnceForReply(
      _PaginationParams(
        ref: ref,
        conv: conv,
        selectedTextChannelId: selectedTextChannelId,
        selectedChannelId: selectedChannelId,
        includeUnchanneled: includeUnchanneled,
        replyToId: replyToId,
        controller: controller,
        a: a,
        mounted: mounted,
        resolveMessages: resolveMessages,
      ),
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
