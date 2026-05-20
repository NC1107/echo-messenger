/// Discord-style channel drawer for mobile + tablet portrait windows.
///
/// On wide viewports the column-layout series renders `ChannelColumn` as
/// a sticky left rail. That doesn't fit a phone, so on narrow viewports
/// we put the same vertical list behind an edge-swipe drawer instead:
/// the chat stays full-screen, swiping right from the left edge pulls
/// the channel list in over the chat, and tapping a channel closes the
/// drawer and switches the chat focus to that channel.
///
/// A 56-wide group rail on the far left mirrors Discord's "server bar"
/// so users can also hop to another group without leaving the drawer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/conversations_provider.dart';
import '../theme/echo_theme.dart';
import 'avatar_utils.dart' show buildAvatar, groupAvatarColor;
import 'channel_column.dart';

class MobileChannelDrawer extends ConsumerWidget {
  final Conversation conversation;
  final String? selectedTextChannelId;
  final ValueChanged<String?> onTextChannelChanged;
  final ValueChanged<String> onConversationSelected;
  final VoidCallback? onShowLounge;

  /// Total drawer width on a phone: 56-wide group rail + 232-wide
  /// channel column = 288. Stays under the 304 default that Flutter's
  /// `Drawer` uses, so the swipe behaviour and Material defaults
  /// continue to work without overrides.
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
    final convs = ref
        .watch(conversationsProvider)
        .conversations
        .where((c) => c.isGroup)
        .toList();
    return Drawer(
      width: drawerWidth,
      backgroundColor: context.sidebarBg,
      child: SafeArea(
        child: Row(
          children: [
            _GroupRail(
              groups: convs,
              activeId: conversation.id,
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

class _GroupRail extends StatelessWidget {
  final List<Conversation> groups;
  final String activeId;
  final ValueChanged<String> onSelect;

  const _GroupRail({
    required this.groups,
    required this.activeId,
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
        itemCount: groups.length,
        itemBuilder: (_, i) {
          final g = groups[i];
          final active = g.id == activeId;
          final name = g.displayName('');
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
                    label: 'group ${name.isEmpty ? "unnamed" : name}',
                    button: true,
                    selected: active,
                    child: InkResponse(
                      onTap: () => onSelect(g.id),
                      radius: 24,
                      child: buildAvatar(
                        name: name,
                        radius: 20,
                        bgColor: groupAvatarColor(g.id),
                        fallbackIcon: const Icon(
                          Icons.group,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
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
}
