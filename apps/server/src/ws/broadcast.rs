//! Shared WebSocket broadcast helpers.
//!
//! Multiple route modules (`channels`, `messages`, `groups`, `reactions`,
//! ...) need the same "look up the members of a conversation, serialize an
//! event, fan it out over the hub" pattern. Before #834 each module kept
//! its own near-identical helper. This module exposes the two flavours so
//! the call sites stay one line:
//!
//! - [`broadcast_to_conversation`] -- canonical path that goes through
//!   [`db::groups::get_conversation_member_ids`] (a fresh DB hit) and
//!   delegates to [`Hub::broadcast_json`]. Use this for events on
//!   admin/structural changes where the member list could have just
//!   mutated.
//! - [`broadcast_to_conversation_cached`] -- hot-path variant that reads
//!   the membership list from the LRU cache maintained by
//!   [`typing_service::get_member_ids_cached`]. Use this for high-volume
//!   reaction-style events where the member list is unlikely to change
//!   between the previous typing/presence fanout and now.
//!
//! Presence broadcasts (`users::broadcast_presence_with_status`) are
//! intentionally NOT migrated -- they fan out over the contact graph
//! (`db::contacts::list_contact_user_ids`), not conversation membership.

use serde::Serialize;
use uuid::Uuid;

use crate::db;
use crate::routes::AppState;
use crate::ws::typing_service::get_member_ids_cached;

/// Resolve the member set via the canonical DB query and fan out `event`
/// to every connected member through the hub. Errors are logged at WARN
/// and swallowed; broadcasts are best-effort by design and must not
/// surface to the originating HTTP caller.
pub async fn broadcast_to_conversation<T: Serialize>(
    state: &AppState,
    conversation_id: Uuid,
    event: &T,
) {
    let member_ids =
        match db::groups::get_conversation_member_ids(&state.pool, conversation_id).await {
            Ok(ids) => ids,
            Err(e) => {
                tracing::warn!(
                    %conversation_id,
                    "broadcast_to_conversation: member lookup failed: {e:?}"
                );
                return;
            }
        };
    let json = match serde_json::to_string(event) {
        Ok(j) => j,
        Err(e) => {
            tracing::warn!(
                %conversation_id,
                "broadcast_to_conversation: serialize failed: {e:?}"
            );
            return;
        }
    };
    state.hub.broadcast_json(&member_ids, &json, None);
}

/// Variant that uses the typing/presence LRU member cache instead of a
/// fresh DB query. Suitable for hot-path events (reactions, read
/// receipts) where the conversation membership is unlikely to have
/// changed since the last typing/presence event populated the cache.
pub async fn broadcast_to_conversation_cached<T: Serialize>(
    state: &AppState,
    conversation_id: Uuid,
    event: &T,
    exclude_user_id: Option<Uuid>,
) {
    let member_ids = match get_member_ids_cached(&state.pool, conversation_id).await {
        Ok(ids) => ids,
        Err(e) => {
            tracing::warn!(
                %conversation_id,
                "broadcast_to_conversation_cached: member lookup failed: {e:?}"
            );
            return;
        }
    };
    let json = match serde_json::to_string(event) {
        Ok(j) => j,
        Err(e) => {
            tracing::warn!(
                %conversation_id,
                "broadcast_to_conversation_cached: serialize failed: {e:?}"
            );
            return;
        }
    };
    let msg = axum::extract::ws::Message::Text(json.as_str().into());
    for member_id in member_ids {
        if Some(member_id) == exclude_user_id {
            continue;
        }
        state.hub.send_to(&member_id, msg.clone());
    }
}
