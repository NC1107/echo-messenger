//! Typing indicators, read receipts, presence, and membership caches.

use axum::extract::ws::Message as WsMessage;
use dashmap::DashMap;
use std::sync::LazyLock;
use std::time::Duration;
use tokio::time::Instant;
use uuid::Uuid;

use crate::db;
use crate::routes::AppState;
use crate::types::ConversationKind;
use crate::ws::handler::ServerMessage;

/// In-memory cache for conversation membership checks used by the typing
/// indicator path.  Keyed by (user_id, conversation_id), stores the
/// tokio::time::Instant when membership was last verified.  Entries older
/// than `MEMBERSHIP_CACHE_TTL` are treated as expired and re-verified
/// against the database.
static MEMBERSHIP_CACHE: LazyLock<DashMap<(Uuid, Uuid), Instant>> = LazyLock::new(DashMap::new);
pub(super) const MEMBERSHIP_CACHE_TTL: Duration = Duration::from_secs(60);

/// Cached conversation member IDs.  Keyed by conversation_id, stores the
/// member list and the instant it was fetched.  Same TTL as membership cache.
static MEMBER_IDS_CACHE: LazyLock<DashMap<Uuid, (Vec<Uuid>, Instant)>> =
    LazyLock::new(DashMap::new);

/// Cached conversation kind (e.g. "dm", "group").  Avoids a DB hit on every
/// typing indicator for the same conversation.
static CONV_KIND_CACHE: LazyLock<DashMap<Uuid, (String, Instant)>> = LazyLock::new(DashMap::new);

/// Check conversation membership using the in-memory cache.
/// Returns true if the user is a verified member. Cache entries expire
/// after `MEMBERSHIP_CACHE_TTL` (60 seconds).
pub(super) async fn check_membership_cached(
    pool: &sqlx::PgPool,
    conversation_id: Uuid,
    user_id: Uuid,
) -> bool {
    let cache_key = (user_id, conversation_id);

    // Fast path: check cache
    if let Some(entry) = MEMBERSHIP_CACHE.get(&cache_key)
        && entry.value().elapsed() < MEMBERSHIP_CACHE_TTL
    {
        return true;
    }

    // Slow path: hit database
    let is_member = match db::groups::is_member(pool, conversation_id, user_id).await {
        Ok(m) => m,
        Err(_) => return false,
    };

    if is_member {
        MEMBERSHIP_CACHE.insert(cache_key, Instant::now());
    } else {
        // Evict stale positive entry if membership was revoked
        MEMBERSHIP_CACHE.remove(&cache_key);
    }

    is_member
}

/// Fetch conversation member IDs with a 60-second in-memory cache.
pub(super) async fn get_member_ids_cached(
    pool: &sqlx::PgPool,
    conversation_id: Uuid,
) -> Result<Vec<Uuid>, sqlx::Error> {
    if let Some(entry) = MEMBER_IDS_CACHE.get(&conversation_id)
        && entry.value().1.elapsed() < MEMBERSHIP_CACHE_TTL
    {
        return Ok(entry.value().0.clone());
    }

    let members = db::groups::get_conversation_member_ids(pool, conversation_id).await?;
    MEMBER_IDS_CACHE.insert(conversation_id, (members.clone(), Instant::now()));
    Ok(members)
}

/// Fetch conversation kind with a 60-second in-memory cache.
pub(super) async fn get_conversation_kind_cached(
    pool: &sqlx::PgPool,
    conversation_id: Uuid,
) -> Option<String> {
    if let Some(entry) = CONV_KIND_CACHE.get(&conversation_id)
        && entry.value().1.elapsed() < MEMBERSHIP_CACHE_TTL
    {
        return Some(entry.value().0.clone());
    }

    let kind = db::groups::get_conversation_kind(pool, conversation_id)
        .await
        .ok()??;
    CONV_KIND_CACHE.insert(conversation_id, (kind.clone(), Instant::now()));
    Some(kind)
}

/// Invalidate the member-ID and membership caches for a conversation.
/// Call this when members are added, removed, or banned so revoked members
/// cannot continue to use cached positive membership entries.
pub fn invalidate_member_cache(conversation_id: Uuid) {
    MEMBER_IDS_CACHE.remove(&conversation_id);
    MEMBERSHIP_CACHE.retain(|(_, conv_id), _| *conv_id != conversation_id);
}

/// Drop cache entries older than 2× their TTL across all three caches.
/// Called from the cleanup scheduler so stale entries don't accumulate on
/// long-running servers.
pub fn sweep_expired_caches() {
    let cutoff = MEMBERSHIP_CACHE_TTL * 2;
    let mut membership_evicted = 0usize;
    MEMBERSHIP_CACHE.retain(|_, last_seen| {
        let keep = last_seen.elapsed() < cutoff;
        if !keep {
            membership_evicted += 1;
        }
        keep
    });
    let mut member_ids_evicted = 0usize;
    MEMBER_IDS_CACHE.retain(|_, (_, fetched_at)| {
        let keep = fetched_at.elapsed() < cutoff;
        if !keep {
            member_ids_evicted += 1;
        }
        keep
    });
    let mut kind_evicted = 0usize;
    CONV_KIND_CACHE.retain(|_, (_, fetched_at)| {
        let keep = fetched_at.elapsed() < cutoff;
        if !keep {
            kind_evicted += 1;
        }
        keep
    });
    if membership_evicted > 0 || member_ids_evicted > 0 || kind_evicted > 0 {
        tracing::debug!(
            membership_evicted,
            member_ids_evicted,
            kind_evicted,
            "ws cache sweep"
        );
    }
}

pub(super) async fn handle_typing(
    state: &AppState,
    sender_id: Uuid,
    sender_username: &str,
    conversation_id: Uuid,
    channel_id: Option<Uuid>,
) {
    // Verify membership via cache (avoids DB hit on every keystroke)
    if !check_membership_cached(&state.pool, conversation_id, sender_id).await {
        return;
    }

    let kind = match get_conversation_kind_cached(&state.pool, conversation_id).await {
        Some(k) => k,
        None => return,
    };

    let mut resolved_channel_id = None;
    if ConversationKind::from_str_opt(&kind) == Some(ConversationKind::Group)
        && let Some(cid) = channel_id
    {
        let channel = match db::channels::get_channel(&state.pool, cid).await {
            Ok(Some(c)) => c,
            _ => return,
        };
        if channel.conversation_id != conversation_id || channel.kind != "text" {
            return;
        }
        resolved_channel_id = Some(cid);
    }

    let member_ids = match get_member_ids_cached(&state.pool, conversation_id).await {
        Ok(ids) => ids,
        Err(_) => return,
    };

    let event = ServerMessage::Typing {
        conversation_id,
        channel_id: resolved_channel_id,
        user_id: sender_id,
        from_username: sender_username.to_string(),
    };
    if let Ok(json) = serde_json::to_string(&event) {
        state
            .hub
            .broadcast_json(&member_ids, &json, Some(sender_id));
    }
}

pub(super) async fn handle_read_receipt(state: &AppState, sender_id: Uuid, conversation_id: Uuid) {
    if !check_membership_cached(&state.pool, conversation_id, sender_id).await {
        return;
    }

    // Enforce sender preference: when disabled, do not persist or broadcast.
    let privacy = match db::users::get_privacy_preferences(&state.pool, sender_id).await {
        Ok(Some(p)) => p,
        _ => return,
    };
    if !privacy.read_receipts_enabled {
        return;
    }

    // Persist the read receipt
    let _ = db::reactions::mark_read(&state.pool, conversation_id, sender_id).await;

    // Broadcast to other members
    let member_ids = match get_member_ids_cached(&state.pool, conversation_id).await {
        Ok(ids) => ids,
        Err(_) => return,
    };

    let event = ServerMessage::ReadReceipt {
        conversation_id,
        user_id: sender_id,
    };
    if let Ok(json) = serde_json::to_string(&event) {
        state
            .hub
            .broadcast_json(&member_ids, &json, Some(sender_id));
    }
}

pub(super) async fn broadcast_presence(
    state: &AppState,
    user_id: Uuid,
    username: &str,
    status: &str,
) {
    // Gate on first-device-up / last-device-down so multi-device reconnects
    // don't surface online/offline flapping to contacts.
    let dev_count = state.hub.device_count(&user_id);
    let should_broadcast = match status {
        "online" => dev_count == 1,
        "offline" => dev_count == 0,
        _ => true,
    };
    if !should_broadcast {
        return;
    }

    let contact_ids = match db::contacts::list_contact_user_ids(&state.pool, user_id).await {
        Ok(ids) => ids,
        Err(e) => {
            tracing::warn!("Failed to fetch contacts for presence broadcast: {e}");
            return;
        }
    };

    // When coming online, look up stored presence_status so we broadcast
    // the right status (e.g. "away" or "dnd") rather than always "online".
    // For "offline" (disconnect), always broadcast "offline" regardless of
    // stored status. Invisible users also appear offline -- and we omit
    // the presence_status field entirely so observers cannot distinguish
    // invisible from truly offline.
    let (broadcast_status, presence_status) = if status == "offline" {
        ("offline".to_string(), None)
    } else {
        let stored = db::users::get_presence_status(&state.pool, user_id)
            .await
            .unwrap_or(None)
            .unwrap_or_else(|| "online".to_string());
        if stored == "invisible" {
            ("offline".to_string(), None)
        } else {
            (stored.clone(), Some(stored))
        }
    };

    let mut presence = serde_json::json!({
        "type": "presence",
        "user_id": user_id,
        "username": username,
        "status": broadcast_status,
    });
    if let Some(ps) = presence_status {
        presence["presence_status"] = serde_json::Value::String(ps);
    }
    // Stamp last_seen_at on offline transitions so peers can render
    // "last seen <relative>" in chat headers (#503).
    if broadcast_status == "offline" {
        presence["last_seen_at"] = serde_json::Value::String(
            chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        );
    }
    let json = match serde_json::to_string(&presence) {
        Ok(j) => j,
        Err(_) => return,
    };

    // Build once; clone is O(1) on Bytes-backed Message::Text.
    let msg = WsMessage::Text(json.into());
    for cid in &contact_ids {
        state.hub.send_to(cid, msg.clone());
    }
}
