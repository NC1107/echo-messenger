import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chat_message.dart';
import '../../models/conversation.dart';
import '../../providers/auth_provider.dart';
import '../../providers/channel_layout_provider.dart';
import '../../providers/chat_provider.dart';
import '../../screens/safety_number_screen.dart';
import '../../screens/user_profile_screen.dart';
import '../../services/saved_messages_service.dart';
import '../../theme/echo_theme.dart';
import '../channel_bar.dart';
import '../channel_column.dart';
import '../chat_header_bar.dart';
import '../chat_input_bar.dart';
import '../encryption_status_banner.dart';
import '../mobile_channel_drawer.dart';
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
    required this.hideVoiceDock,
    required this.typingUsers,
    required this.isDragOver,
    required this.chatInputBarKey,
    required this.onBack,
    required this.onMembersToggle,
    required this.onGroupInfo,
    required this.onShowLounge,
    required this.onTextChannelChanged,
    required this.onVoiceChannelChanged,
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
    this.onConversationSelected,
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
  final bool hideVoiceDock;
  final List<String> typingUsers;
  final bool isDragOver;
  final GlobalKey<ChatInputBarState> chatInputBarKey;
  final VoidCallback? onBack;
  final VoidCallback? onMembersToggle;
  final VoidCallback? onGroupInfo;
  final VoidCallback? onShowLounge;
  final ValueChanged<String?> onTextChannelChanged;
  final ValueChanged<String?> onVoiceChannelChanged;
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

  /// Optional: tapping a group in the mobile drawer's left rail bubbles
  /// up here so the host screen can swap `_selectedConversation`. Not
  /// set on desktop (the drawer never renders there).
  final ValueChanged<String>? onConversationSelected;
}

/// Column-mode visibility branches on viewport width:
///
///   • >= 900 px → desktop side-rail beside the chat (`useColumn`).
///   • <  900 px → Discord-style edge-swipe drawer (`useColumnDrawer`).
///
/// Both surfaces feed off the same channel state and the same join /
/// text-channel callbacks, so behaviour is consistent between layouts
/// (#prod-column-layout-2026-05-20).
class _ColumnLayoutDecision {
  final bool useColumn;
  final bool useColumnDrawer;

  const _ColumnLayoutDecision({
    required this.useColumn,
    required this.useColumnDrawer,
  });
}

_ColumnLayoutDecision _resolveColumnLayout(
  BuildContext context,
  WidgetRef ref,
  ChatPanelBodyParams p,
) {
  final layout = ref.watch(channelLayoutProvider);
  final width = MediaQuery.of(context).size.width;
  final columnRequested = layout == ChannelLayout.column && p.conv.isGroup;
  return _ColumnLayoutDecision(
    useColumn: columnRequested && width >= 900,
    useColumnDrawer: columnRequested && width < 900,
  );
}

Widget _wrapForColumnLayout(
  Widget chatArea,
  ChatPanelBodyParams p,
  _ColumnLayoutDecision dec,
) {
  if (dec.useColumn) {
    return Row(
      children: [
        ChannelColumn(
          conversation: p.conv,
          selectedTextChannelId: p.selectedTextChannelId,
          onTextChannelChanged: p.onTextChannelChanged,
          onShowLounge: p.onShowLounge,
        ),
        Expanded(child: chatArea),
      ],
    );
  }
  if (dec.useColumnDrawer && p.onConversationSelected != null) {
    // Inner Scaffold so the Drawer's built-in edge-swipe gesture works
    // without colliding with the outer narrow-layout Scaffold.
    return Scaffold(
      backgroundColor: Colors.transparent,
      drawer: MobileChannelDrawer(
        conversation: p.conv,
        selectedTextChannelId: p.selectedTextChannelId,
        onTextChannelChanged: p.onTextChannelChanged,
        onConversationSelected: p.onConversationSelected!,
        onShowLounge: p.onShowLounge,
      ),
      body: chatArea,
    );
  }
  return chatArea;
}

Widget buildChatContentBox(
  BuildContext context,
  WidgetRef ref,
  ChatPanelBodyParams p,
) {
  final chatGradient = context.chatBgGradient;
  final dec = _resolveColumnLayout(context, ref, p);
  final useColumn = dec.useColumn;
  final useColumnDrawer = dec.useColumnDrawer;
  final chatArea = DecoratedBox(
    decoration: chatGradient != null
        ? BoxDecoration(gradient: chatGradient)
        : BoxDecoration(color: context.chatBg),
    child: Stack(
      children: [
        // Hidden live region (#495/#630); first Stack child so its index stays stable across pill toggles.
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
              onMembersToggle: p.onMembersToggle,
              onGroupInfo: p.onGroupInfo,
              // Column-mode rail already shows group identity; suppress duplicate label here.
              hideGroupIdentity: useColumn,
            ),
            if (p.conv.isGroup && !useColumn && !useColumnDrawer)
              ChannelBar(
                conversationId: p.conv.id,
                selectedTextChannelId: p.selectedTextChannelId,
                activeVoiceChannelId: p.activeVoiceChannelId,
                hideVoiceDock: p.hideVoiceDock,
                onTextChannelChanged: p.onTextChannelChanged,
                onVoiceChannelChanged: p.onVoiceChannelChanged,
                onShowLounge: p.onShowLounge,
              ),
            // Audit P0-1/P0-2/P0-3: surface keyring/OTP/wedged-session states (renders shrink when idle).
            EncryptionStatusBanner(conversation: p.conv),
            if (p.isLoadingHistory)
              LinearProgressIndicator(
                minHeight: 2,
                color: context.accent,
                backgroundColor: context.surface,
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
                      onReplyInThread: (msg) {
                        // Stamp the reply with the thread root so the
                        // outbound message lands in the thread panel,
                        // not the main timeline.
                        ref
                            .read(chatProvider.notifier)
                            .setReplyTo(msg, asThread: true);
                        // Open the thread panel so the user sees the
                        // active conversation context while typing.
                        p.onOpenThread(msg);
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

  return _wrapForColumnLayout(chatArea, p, dec);
}
