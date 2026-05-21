/// Per-user presence lookup.
///
/// Before this provider every widget that wanted a user's presence wrote
/// the same three lines:
///
/// ```dart
/// final ws = ref.watch(websocketProvider);
/// final status = ws.presenceStatusFor(userId);
/// final isOnline = ws.onlineUsers.contains(userId);
/// ```
///
/// That fans out into a ws-state read on every rebuild, even when the
/// user's specific presence didn't change. The family below selects only
/// the two fields for the user in question, so unrelated presence
/// updates don't trigger rebuilds.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'websocket_provider.dart';

part 'user_presence_provider.g.dart';

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

@Riverpod(keepAlive: true)
UserPresence userPresence(Ref ref, String userId) {
  final isOnline = ref.watch(
    websocketProvider.select((s) => s.onlineUsers.contains(userId)),
  );
  final status = ref.watch(
    websocketProvider.select((s) => s.presenceStatusFor(userId)),
  );
  return UserPresence(status: status, isOnline: isOnline);
}
