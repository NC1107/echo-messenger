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
import 'websocket_provider.dart';

part 'user_presence_provider.g.dart';

@Riverpod(keepAlive: true)
UserPresence userPresence(Ref ref, String userId) {
  return ref.watch(websocketProvider.select((s) => s.presenceFor(userId)));
}
