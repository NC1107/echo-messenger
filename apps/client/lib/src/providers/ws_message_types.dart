/// The WebSocket event-type contract between the Rust server and this client.
///
/// There is no codegen across the Rust↔Dart boundary yet, so these two sets are
/// hand-maintained — but `test/providers/ws_contract_test.dart` fails if the
/// server's typed contract isn't fully handled here, turning a silent
/// event-drop into a red test.
///
/// WHEN YOU ADD A SERVER → CLIENT EVENT:
///  1. add its `type` string to [kServerSentMessageTypes] (mirror of the
///     `ServerMessage` enum in `apps/server/src/ws/protocol.rs`); and
///  2. add a `case` for it in `WsMessageHandler.handleServerMessage` AND its
///     string to [kHandledServerMessageTypes]. A debug `assert` in that
///     switch's `default` branch trips if the set and the switch drift apart.
library;

/// Every `type` the client's WS dispatcher (`handleServerMessage`) has a `case`
/// for. Kept in lockstep with that switch (the `default`-branch assert guards
/// against drift). Superset of [kServerSentMessageTypes] — it also covers
/// ad-hoc broadcast events (reactions, member/channel changes, presence, …)
/// that aren't part of the typed `ServerMessage` enum.
const Set<String> kHandledServerMessageTypes = {
  'new_message',
  'message_sent',
  'typing',
  'reaction',
  'delivered',
  'read_receipt',
  'message_deleted',
  'message_edited',
  'message_expired',
  'message_pinned',
  'message_unpinned',
  'presence',
  'presence_list',
  'channel_created',
  'channel_updated',
  'channel_deleted',
  'voice_session_joined',
  'voice_session_left',
  'voice_session_updated',
  'mention',
  'group_key_rotated',
  'group_key_rotation_requested',
  'self_message',
  'session_replaced',
  'device_revoked',
  'heartbeat',
  'error',
  'voice_signal',
  'key_reset',
  'identity_reset',
  'peer_keys_published',
  'call_started',
  'canvas_event',
  'canvas_authority_changed',
  'member_added',
  'member_role_changed',
};

/// The typed events the server can send — the `ServerMessage` enum's
/// `#[serde(rename = ...)]` tags in `apps/server/src/ws/protocol.rs`. The
/// contract test asserts every one of these is in [kHandledServerMessageTypes];
/// a server event the client silently drops is a real bug.
const Set<String> kServerSentMessageTypes = {
  'new_message',
  'self_message',
  'message_sent',
  'delivered',
  'typing',
  'read_receipt',
  'error',
  'voice_signal',
  'key_reset',
  'call_started',
  'message_expired',
  'device_revoked',
  'peer_keys_published',
  'canvas_event',
  'canvas_authority_changed',
};
