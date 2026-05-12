import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../screens/safety_number_screen.dart';
import '../../screens/user_profile_screen.dart';
import '../../services/saved_messages_service.dart';
import '../../theme/echo_theme.dart';
import '../channel_bar.dart';
import '../chat/session_corrupted_banner.dart';
import '../chat_header_bar.dart';
import '../chat_input_bar.dart';
import '../connection_status_banner.dart';
import '../crypto_degraded_banner.dart';
import '../identity_key_changed_banner.dart';
import '../message_search_overlay.dart';
import 'chat_message_list.dart';
import 'drop_overlay.dart';
import 'floating_date_pill.dart';
import 'new_messages_pill.dart';

/// Build the inner `chatContentBox` Stack for `ChatPanel.build` — the
/// header bar, channel bar, banners, message list, floating pills, input
/// bar, and overlay layers. All Riverpod listening stays in the calling
/// `build` method; this helper receives already-resolved values + callbacks.
class ChatPanelBodyParams {
  ChatPanelBodyParams({
    required this.conv,
    required this.myUserId,
    required this.authToken,
    required this.serverUrl,
    required this.mediaTicket,
    required this.messages,
    required this.memberAvatars,
    required this.selectedTextChannelId,
    required this.selectedChannelId,
    required this.activeVoiceChannelId,
    required this.isLoadingHistory,
    required this.hasMoreHistory,
    required this.displayName,
    required this.scrollController,
    required this.messageKeys,
    required this.savedIds,
    required this.highlightedMessageId,
    required this.unreadBoundaryMessageId,
    required this.unreadBoundaryCount,
    required this.floatingDate,
    required this.floatingDateVisible,
    required this.hasNewMessagesBelow,
    required this.newMessagesBannerText,
    required this.liveRegionAnnouncement,
    required this.showSearch,
    required this.hideVoiceDock,
    required this.hideEncryptionBanner,
    required this.typingUsers,
    required this.isDragOver,
    required this.chatInputBarKey,
    required this.onBack,
    required this.onMembersToggle,
    required this.onGroupInfo,
    required this.onShowLounge,
    required this.onTextChannelChanged,
    required this.onVoiceChannelChanged,
    required this.onSetShowSearch,
    required this.onDismissEncryptionBanner,
    required this.onHighlightMessage,
    required this.onShowReactionPicker,
    required this.onToggleReaction,
    required this.onShowFullReactionPicker,
    required this.onDeleteFailed,
    required this.onConfirmDelete,
    required this.onRetryMessage,
    required this.onOpenThread,
    required this.onPinMessage,
    required this.onUnpinMessage,
    required this.onForwardMessage,
    required this.onSaveMessage,
    required this.onUnsaveMessage,
    required this.onJumpToReplyQuote,
    required this.onOpenImageGallery,
    required this.onScrollToBottom,
    required this.onMessageSent,
    required this.onMediaPickerChanged,
    required this.voiceRenderers,
  });

  final Conversation conv;
  final String myUserId;
  final String authToken;
  final String serverUrl;
  final String? mediaTicket;
  final List<ChatMessage> messages;
  final Map<String, String?> memberAvatars;
  final String? selectedTextChannelId;
  final String? selectedChannelId;
  final String? activeVoiceChannelId;
  final bool isLoadingHistory;
  final bool hasMoreHistory;
  final String displayName;
  final ScrollController scrollController;
  final Map<String, GlobalKey> messageKeys;
  final Set<String> savedIds;
  final String? highlightedMessageId;
  final String? unreadBoundaryMessageId;
  final int unreadBoundaryCount;
  final String? floatingDate;
  final bool floatingDateVisible;
  final bool hasNewMessagesBelow;
  final String newMessagesBannerText;
  final String liveRegionAnnouncement;
  final bool showSearch;
  final bool hideVoiceDock;
  final bool hideEncryptionBanner;
  final List<String> typingUsers;
  final bool isDragOver;
  final GlobalKey<ChatInputBarState> chatInputBarKey;
  final VoidCallback? onBack;
  final VoidCallback? onMembersToggle;
  final VoidCallback? onGroupInfo;
  final VoidCallback? onShowLounge;
  final ValueChanged<String?> onTextChannelChanged;
  final ValueChanged<String?> onVoiceChannelChanged;
  final ValueChanged<bool> onSetShowSearch;
  final VoidCallback onDismissEncryptionBanner;
  final ValueChanged<String> onHighlightMessage;
  final void Function(ChatMessage, Offset) onShowReactionPicker;
  final void Function(ChatMessage, String, bool) onToggleReaction;
  final void Function(ChatMessage) onShowFullReactionPicker;
  final ValueChanged<ChatMessage> onDeleteFailed;
  final ValueChanged<ChatMessage> onConfirmDelete;
  final ValueChanged<ChatMessage> onRetryMessage;
  final ValueChanged<ChatMessage> onOpenThread;
  final ValueChanged<ChatMessage> onPinMessage;
  final ValueChanged<ChatMessage> onUnpinMessage;
  final ValueChanged<ChatMessage> onForwardMessage;
  final ValueChanged<ChatMessage> onSaveMessage;
  final ValueChanged<ChatMessage> onUnsaveMessage;
  final ValueChanged<String> onJumpToReplyQuote;
  final ValueChanged<String> onOpenImageGallery;
  final VoidCallback onScrollToBottom;
  final VoidCallback onMessageSent;
  final VoidCallback onMediaPickerChanged;
  final List<Widget> voiceRenderers;
}

Widget buildChatContentBox(
  BuildContext context,
  WidgetRef ref,
  ChatPanelBodyParams p,
) {
  final chatGradient = context.chatBgGradient;
  return DecoratedBox(
    decoration: chatGradient != null
        ? BoxDecoration(gradient: chatGradient)
        : BoxDecoration(color: context.chatBg),
    child: Stack(
      children: [
        // Hidden live region for screen-reader announcements when peer
        // messages arrive (#495 / #630). Mounted as the first child of
        // the outer Stack so it lives at a stable index in the build
        // tree — Flutter won't recreate the Semantics node when the
        // floating-date pill or new-messages-below pill toggle.
        Semantics(
          liveRegion: true,
          label: p.liveRegionAnnouncement,
          child: const SizedBox.shrink(),
        ),
        Column(
          children: [
            ChatHeaderBar(
              conversation: p.conv,
              myUserId: p.myUserId,
              serverUrl: p.serverUrl,
              onBack: p.onBack,
              showSearch: p.showSearch,
              onToggleSearch: () => p.onSetShowSearch(!p.showSearch),
              onMembersToggle: p.onMembersToggle,
              onGroupInfo: p.onGroupInfo,
              onDismissEncryptionBanner: p.onDismissEncryptionBanner,
              hideEncryptionBanner: p.hideEncryptionBanner,
            ),
            if (p.conv.isGroup)
              ChannelBar(
                conversationId: p.conv.id,
                selectedTextChannelId: p.selectedTextChannelId,
                activeVoiceChannelId: p.activeVoiceChannelId,
                hideVoiceDock: p.hideVoiceDock,
                onTextChannelChanged: p.onTextChannelChanged,
                onVoiceChannelChanged: p.onVoiceChannelChanged,
                onShowLounge: p.onShowLounge,
              ),
            if (p.showSearch)
              MessageSearchOverlay(
                conversationId: p.conv.id,
                onMessageSelected: (messageId) {
                  p.onSetShowSearch(false);
                  p.onHighlightMessage(messageId);
                },
                onClose: () => p.onSetShowSearch(false),
              ),
            if (p.isLoadingHistory)
              LinearProgressIndicator(
                minHeight: 2,
                color: context.accent,
                backgroundColor: context.surface,
              ),
            const ConnectionStatusBanner(),
            const CryptoDegradedBanner(),
            if (!p.conv.isGroup) IdentityKeyChangedBanner(conversation: p.conv),
            if (!p.conv.isGroup)
              Builder(
                builder: (ctx) {
                  final peer = p.conv.members
                      .where((m) => m.userId != p.myUserId)
                      .firstOrNull;
                  if (peer == null) return const SizedBox.shrink();
                  return SessionCorruptedBanner(
                    conversationId: p.conv.id,
                    peerUserId: peer.userId,
                    peerName: peer.username,
                  );
                },
              ),
            Expanded(
              child: GestureDetector(
                onTap: () => FocusScope.of(context).unfocus(),
                child: Stack(
                  children: [
                    ChatMessageList(
                      conv: p.conv,
                      messages: p.messages,
                      memberAvatars: p.memberAvatars,
                      myUserId: p.myUserId,
                      serverUrl: p.serverUrl,
                      authToken: p.authToken,
                      mediaTicket: p.mediaTicket,
                      channelId: p.selectedChannelId,
                      isLoadingHistory: p.isLoadingHistory,
                      hasMoreHistory: p.hasMoreHistory,
                      displayName: p.displayName,
                      scrollController: p.scrollController,
                      messageKeys: p.messageKeys,
                      savedIds: p.savedIds,
                      highlightedMessageId: p.highlightedMessageId,
                      unreadBoundaryMessageId: p.unreadBoundaryMessageId,
                      unreadBoundaryCount: p.unreadBoundaryCount,
                      onReactionTap: p.onShowReactionPicker,
                      onToggleReaction: p.onToggleReaction,
                      onMoreReactions: p.onShowFullReactionPicker,
                      onDeleteFailed: p.onDeleteFailed,
                      onConfirmDelete: p.onConfirmDelete,
                      onRetryMessage: p.onRetryMessage,
                      onEnterEditMode: (msg) {
                        p.chatInputBarKey.currentState?.enterEditMode(msg);
                      },
                      onReply: (msg) {
                        ref.read(chatProvider.notifier).setReplyTo(msg);
                        p.chatInputBarKey.currentState?.requestInputFocus();
                      },
                      onOpenThread: p.onOpenThread,
                      onPin: p.onPinMessage,
                      onUnpin: p.onUnpinMessage,
                      onForward: p.onForwardMessage,
                      onSaveMessage: p.onSaveMessage,
                      onUnsaveMessage: p.onUnsaveMessage,
                      onJumpToReplyQuote: p.onJumpToReplyQuote,
                      onAvatarTap: (userId) {
                        UserProfileScreen.show(context, ref, userId);
                      },
                      onVerifyIdentity: p.conv.isGroup
                          ? null
                          : (message) {
                              final myName =
                                  ref.read(authProvider).username ?? 'You';
                              SafetyNumberScreen.show(
                                context,
                                ref,
                                peerUserId: message.fromUserId,
                                peerUsername: message.fromUsername,
                                myUsername: myName,
                              );
                            },
                      onImageTap: p.onOpenImageGallery,
                      isMessageSaved: (id) =>
                          SavedMessagesService.instance.isMessageSaved(id),
                      onSayHi: () {
                        p.chatInputBarKey.currentState?.preFillText(
                          'Hey! \u{1F44B}',
                        );
                      },
                    ),
                    if (p.floatingDate != null)
                      FloatingDatePill(
                        visible: p.floatingDateVisible,
                        date: p.floatingDate,
                      ),
                    if (p.hasNewMessagesBelow)
                      NewMessagesPill(
                        text: p.newMessagesBannerText,
                        onTap: p.onScrollToBottom,
                      ),
                    // Live region moved to the outer Stack so its index
                    // in the tree is stable across pill toggles (#630).
                  ],
                ),
              ),
            ),
            ChatInputBar(
              key: p.chatInputBarKey,
              conversation: p.conv,
              selectedTextChannelId: p.selectedTextChannelId,
              effectiveActiveVoiceChannelId: p.activeVoiceChannelId,
              typingUsers: p.typingUsers,
              onMessageSent: p.onMessageSent,
              onMediaPickerChanged: p.onMediaPickerChanged,
            ),
            ...p.voiceRenderers,
          ],
        ),
        // Floating emoji/GIF picker — rendered above the message list so taps
        // aren't absorbed by the ListView's gesture recognizers.
        if (p.chatInputBarKey.currentState?.showMediaPicker ?? false)
          Positioned(
            bottom: 80,
            right: 16,
            child: p.chatInputBarKey.currentState!.buildMediaPickerPanel(),
          ),
        // Drag-and-drop overlay
        if (p.isDragOver) DropOverlay(isDragOver: p.isDragOver),
      ],
    ),
  );
}
