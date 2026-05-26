/// Discord-style channel drawer for mobile + tablet portrait windows.
///
/// On wide viewports the column-layout series renders `ChannelColumn` as
/// a sticky left rail. That doesn't fit a phone, so on narrow viewports
/// we put the same vertical list behind an edge-swipe drawer instead:
/// the chat stays full-screen, swiping right from the left edge pulls
/// the channel list in over the chat, and tapping a channel closes the
/// drawer and switches the chat focus to that channel.
///
/// The 56-wide rail on the far left mirrors the Chats tab — every
/// conversation (groups *and* 1:1 DMs) gets a circular avatar so
/// users can hop sideways without leaving the drawer. Groups show a
/// group-colour avatar; DMs show the peer's avatar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/conversation_filter_provider.dart';
import '../providers/server_url_provider.dart';
import '../theme/echo_theme.dart';
import 'avatar_utils.dart' show buildAvatar, groupAvatarColor, resolveAvatarUrl;
import 'channel_column.dart';

class MobileChannelDrawer extends ConsumerWidget {
  final Conversation conversation;
  final String? selectedTextChannelId;
  final ValueChanged<String?> onTextChannelChanged;
  final ValueChanged<String> onConversationSelected;
  final VoidCallback? onShowLounge;

  /// Total drawer width on a phone: 56-wide rail + 232-wide channel
  /// column = 288. Stays under the 304 default that Flutter's `Drawer`
  /// uses, so the swipe behaviour and Material defaults continue to
  /// work without overrides.
  static const double railWidth = 56;
  static const double drawerWidth = railWidth + ChannelColumn.width - 28;

  const MobileChannelDrawer({
    super.key,
    required this.conversation,
    required this.selectedTextChannelId,
    required this.onTextChannelChanged,
    required this.onConversationSelected,
    this.onShowLounge,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Same sort/filter the home Chats tab uses, so the rail visibly
    // matches what the user just saw before opening this conversation.
    final convs = ref.watch(sortedConversationsProvider);
    final myUserId = ref.watch(authProvider.select((s) => s.userId)) ?? '';
    final serverUrl = ref.watch(serverUrlProvider);
    return Drawer(
      width: drawerWidth,
      backgroundColor: context.sidebarBg,
      child: SafeArea(
        child: Row(
          children: [
            _ConversationRail(
              conversations: convs,
              activeId: conversation.id,
              myUserId: myUserId,
              serverUrl: serverUrl,
              onSelect: (id) {
                onConversationSelected(id);
                Navigator.of(context).maybePop();
              },
            ),
            Expanded(
              child: ChannelColumn(
                conversation: conversation,
                selectedTextChannelId: selectedTextChannelId,
                onTextChannelChanged: (id) {
                  onTextChannelChanged(id);
                  Navigator.of(context).maybePop();
                },
                onShowLounge: () {
                  onShowLounge?.call();
                  Navigator.of(context).maybePop();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationRail extends StatelessWidget {
  final List<Conversation> conversations;
  final String activeId;
  final String myUserId;
  final String serverUrl;
  final ValueChanged<String> onSelect;

  const _ConversationRail({
    required this.conversations,
    required this.activeId,
    required this.myUserId,
    required this.serverUrl,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: MobileChannelDrawer.railWidth,
      decoration: BoxDecoration(
        color: context.mainBg,
        border: Border(right: BorderSide(color: context.border)),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: conversations.length,
        itemBuilder: (_, i) {
          final c = conversations[i];
          final active = c.id == activeId;
          final name = c.displayName(myUserId);
          final avatar = _avatarFor(c, name);
          final semanticsPrefix = c.isGroup ? 'group' : 'chat with';
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Stack(
              children: [
                if (active)
                  Positioned(
                    left: 0,
                    top: 6,
                    bottom: 6,
                    child: Container(
                      width: 3,
                      decoration: BoxDecoration(
                        color: context.accent,
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(2),
                          bottomRight: Radius.circular(2),
                        ),
                      ),
                    ),
                  ),
                Center(
                  child: Semantics(
                    container: true,
                    label:
                        '$semanticsPrefix ${name.isEmpty ? "unnamed" : name}',
                    button: true,
                    selected: active,
                    child: InkResponse(
                      onTap: () => onSelect(c.id),
                      radius: 24,
                      // ExcludeSemantics so the fallback initial doesn't append to the row's label.
                      child: ExcludeSemantics(child: avatar),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _avatarFor(Conversation c, String displayName) {
    if (c.isGroup) {
      return buildAvatar(
        name: displayName,
        radius: 20,
        imageUrl: resolveAvatarUrl(c.iconUrl, serverUrl),
        bgColor: groupAvatarColor(c.id),
        fallbackIcon: const Icon(Icons.group, size: 18, color: Colors.white),
      );
    }
    final peer = c.members.where((m) => m.userId != myUserId).firstOrNull;
    return buildAvatar(
      name: displayName,
      radius: 20,
      imageUrl: resolveAvatarUrl(peer?.avatarUrl, serverUrl),
    );
  }
}
