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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../utils/presence.dart';
import 'auth/auth_provider.dart';
import 'websocket_provider.dart';

part 'user_presence_provider.g.dart';

@Riverpod(keepAlive: true)
UserPresence userPresence(Ref ref, String userId) {
  // The server does not echo presence_update back to the connecting user,
  // so presenceFor(myUserId) returns offline/empty until a contact triggers
  // a broadcast. Surface the locally-known presence from authProvider for
  // self so the user sees their own status dot light up immediately.
  final myUserId = ref.watch(authProvider.select((s) => s.userId));
  if (myUserId != null && myUserId == userId) {
    final myStatus = ref.watch(authProvider.select((s) => s.presenceStatus));
    return UserPresence(status: myStatus, isOnline: true);
  }
  return ref.watch(websocketProvider.select((s) => s.presenceFor(userId)));
}
