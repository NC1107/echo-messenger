import 'package:flutter/material.dart';

import '../models/contact.dart';
import '../theme/echo_theme.dart';
import 'avatar_utils.dart' show buildAvatar, resolveAvatarUrl;

class ContactItem extends StatefulWidget {
  final Contact contact;
  final String serverUrl;
  final VoidCallback onMessage;
  final VoidCallback onProfile;
  final Set<String> onlineUsers;

  const ContactItem({
    super.key,
    required this.contact,
    required this.serverUrl,
    required this.onMessage,
    required this.onProfile,
    this.onlineUsers = const {},
  });

  @override
  State<ContactItem> createState() => _ContactItemState();
}

class _ContactItemState extends State<ContactItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final contact = widget.contact;
    final username = contact.username;
    final displayName = contact.displayName;
    final fullAvatarUrl = resolveAvatarUrl(contact.avatarUrl, widget.serverUrl);
    final isOnline = widget.onlineUsers.contains(contact.userId);

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onHover: (hovered) => setState(() => _isHovered = hovered),
        onTap: widget.onProfile,
        child: Container(
          height: 56,
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: _isHovered ? context.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  label: 'contact: $username',
                  child: Row(
                    children: [
                      // Avatar with online dot
                      Stack(
                        children: [
                          buildAvatar(
                            name: username,
                            radius: 18,
                            imageUrl: fullAvatarUrl,
                          ),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: isOnline
                                    ? EchoTheme.online
                                    : context.textMuted,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: context.sidebarBg,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      // Name
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayName ?? username,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: context.textPrimary,
                              ),
                            ),
                            if (displayName != null)
                              Text(
                                '@$username',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.textMuted,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Semantics(
                label: 'message $username',
                button: true,
                child: SizedBox(
                  height: 28,
                  child: Material(
                    color: context.accentLight,
                    borderRadius: BorderRadius.circular(6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: widget.onMessage,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Center(
                          child: Text(
                            'Message',
                            style: TextStyle(
                              color: context.accent,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
