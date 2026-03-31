import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/conversations_provider.dart';
import '../providers/auth_provider.dart';
import '../theme/echo_theme.dart';

class ServerRail extends ConsumerWidget {
  final VoidCallback? onDmTap;
  final VoidCallback? onCreateTap;
  final VoidCallback? onSettingsTap;
  final String? selectedGroupId;
  final bool dmSelected;
  final void Function(Conversation group)? onGroupTap;

  const ServerRail({
    super.key,
    this.onDmTap,
    this.onCreateTap,
    this.onSettingsTap,
    this.selectedGroupId,
    this.dmSelected = true,
    this.onGroupTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversationsState = ref.watch(conversationsProvider);
    final myUserId = ref.watch(authProvider).userId ?? '';

    // Get distinct group conversations
    final groups = conversationsState.conversations
        .where((c) => c.isGroup)
        .toList();

    return Container(
      width: 72,
      color: EchoTheme.background,
      child: Column(
        children: [
          const SizedBox(height: 8),
          // DM button
          _RailIcon(
            isSelected: dmSelected,
            tooltip: 'Direct Messages',
            onTap: onDmTap,
            child: const Icon(Icons.chat_bubble, size: 22, color: Colors.white),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Divider(color: EchoTheme.divider, thickness: 2),
          ),
          // Group/server icons
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: groups.map((group) {
                final name = group.displayName(myUserId);
                final initial =
                    name.isNotEmpty ? name[0].toUpperCase() : '?';
                return _RailIcon(
                  isSelected: selectedGroupId == group.id,
                  tooltip: name,
                  onTap: () => onGroupTap?.call(group),
                  child: Text(
                    initial,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          // Add button
          _RailIcon(
            isSelected: false,
            tooltip: 'Add a Server',
            onTap: onCreateTap,
            isAction: true,
            child: const Icon(Icons.add, size: 22, color: EchoTheme.online),
          ),
          const SizedBox(height: 4),
          // Settings
          _RailIcon(
            isSelected: false,
            tooltip: 'Settings',
            onTap: onSettingsTap,
            isAction: true,
            child: const Icon(Icons.settings, size: 20, color: EchoTheme.textSecondary),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _RailIcon extends StatefulWidget {
  final bool isSelected;
  final String tooltip;
  final VoidCallback? onTap;
  final Widget child;
  final bool isAction;

  const _RailIcon({
    required this.isSelected,
    required this.tooltip,
    this.onTap,
    required this.child,
    this.isAction = false,
  });

  @override
  State<_RailIcon> createState() => _RailIconState();
}

class _RailIconState extends State<_RailIcon> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.isSelected || _isHovered;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Center(
        child: Row(
          children: [
            // Left indicator pill
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 4,
              height: widget.isSelected
                  ? 36
                  : _isHovered
                      ? 20
                      : 0,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: Tooltip(
                  message: widget.tooltip,
                  preferBelow: false,
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _isHovered = true),
                    onExit: (_) => setState(() => _isHovered = false),
                    child: GestureDetector(
                      onTap: widget.onTap,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: widget.isAction
                              ? (isActive
                                  ? EchoTheme.online
                                  : EchoTheme.panelBg)
                              : (isActive
                                  ? EchoTheme.accent
                                  : EchoTheme.panelBg),
                          borderRadius: BorderRadius.circular(
                            isActive ? 16 : 24,
                          ),
                        ),
                        child: Center(child: widget.child),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
