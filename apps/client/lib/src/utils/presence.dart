/// Shared mappings for a user's presence string (`'online' / 'away' / 'dnd'
/// / 'invisible' / 'offline'`) to UI artefacts (colour swatch, screen-reader
/// label, etc.).
///
/// Before this file, the same `switch (status) { 'online' => …, 'away' => … }`
/// was inlined in `conversation_item.dart`, `conversation_panel.dart`,
/// `members_panel.dart`, `user_profile_screen.dart` and the avatar widget.
/// Each copy drifted slightly — the "unknown status" fallback was sometimes
/// `online`, sometimes `offline-grey`, sometimes the offline string. This
/// file is the one place to read and update those mappings.
library;

import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

const Color _offlineGray = Color(0xFF6B6B6F);

/// Snapshot of a single user's presence: WebSocket-tracked online flag
/// + last-seen status string. Constructed by `WebSocketState.presenceFor`
/// and `userPresenceProvider`; consumed everywhere a widget needs to
/// colour a dot, label an activity line, or sort by presence.
@immutable
class UserPresence {
  final String status;
  final bool isOnline;
  const UserPresence({required this.status, required this.isOnline});

  /// Sentinel for "we have no record of this user yet" — looks the same
  /// as a deliberately-offline user to peers.
  static const offline = UserPresence(status: 'offline', isOnline: false);

  @override
  bool operator ==(Object other) =>
      other is UserPresence &&
      other.status == status &&
      other.isOnline == isOnline;

  @override
  int get hashCode => Object.hash(status, isOnline);
}

/// Resolve the colour for a presence dot, ring, or badge.
///
/// Off-line and `'invisible'` both fall through to the muted grey so they
/// look indistinguishable to peers, matching server-side semantics.
Color presenceColor(String status, {bool isOnline = true}) {
  if (!isOnline) return _offlineGray;
  return switch (status) {
    'online' => EchoTheme.online,
    'away' => EchoTheme.warning,
    'dnd' => EchoTheme.danger,
    'invisible' => _offlineGray,
    _ => _offlineGray,
  };
}

/// Human-readable, lower-case label suitable for the activity line under
/// a username. Pairs with [presenceColor] for the dot.
String presenceLabel(String status, {bool isOnline = true}) {
  if (!isOnline || status == 'invisible') return 'offline';
  return switch (status) {
    'online' => 'online',
    'away' => 'away',
    'dnd' => 'do not disturb',
    _ => 'online',
  };
}
