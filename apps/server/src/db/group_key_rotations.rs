//! `group_key_rotations` — append-only audit log for group key rotations.
//!
//! Audit OQ-13. One row per successful rotation, visible to group
//! admins under "Encryption activity" in group settings. See the
//! migration `20260518100000_group_key_rotations.sql` for the schema
//! rationale.

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::{Executor, FromRow, PgPool, Postgres};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct GroupKeyRotationRow {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub triggered_by_user_id: Uuid,
    pub triggered_by_event: String,
    pub key_version: i32,
    pub completed_at: DateTime<Utc>,
    pub completed_by_user_id: Uuid,
}

/// Insert a rotation-completed row. Called inside the same transaction
/// as the new envelope upload so the audit trail and the envelope
/// table never disagree about which rotations actually committed.
///
/// `triggered_by_event` is a free-form tag describing why the rotator
/// fired (`first_key`, `explicit_rotate`, `membership_change`, …).
/// Stored as text so future event types don't need a migration.
///
/// Returns `sqlx::Error::Database` with code 23505 (UNIQUE violation)
/// when `(conversation_id, key_version)` already has an audit row.
/// Callers should map this to a 409 Conflict — the underlying
/// `group_keys` table already raised the same conflict by the time we
/// reach this insert, so in practice the audit-table conflict is a
/// belt-and-suspenders guard rather than the primary error surface.
pub async fn insert_completed_rotation<'e, E>(
    executor: E,
    conversation_id: Uuid,
    triggered_by_user_id: Uuid,
    triggered_by_event: &str,
    key_version: i32,
    completed_by_user_id: Uuid,
) -> Result<GroupKeyRotationRow, sqlx::Error>
where
    E: Executor<'e, Database = Postgres>,
{
    sqlx::query_as::<_, GroupKeyRotationRow>(
        "INSERT INTO group_key_rotations \
                (conversation_id, triggered_by_user_id, triggered_by_event, \
                 key_version, completed_by_user_id) \
         VALUES ($1, $2, $3, $4, $5) \
         RETURNING id, conversation_id, triggered_by_user_id, triggered_by_event, \
                   key_version, completed_at, completed_by_user_id",
    )
    .bind(conversation_id)
    .bind(triggered_by_user_id)
    .bind(triggered_by_event)
    .bind(key_version)
    .bind(completed_by_user_id)
    .fetch_one(executor)
    .await
}

/// List rotations for a single conversation, newest-first. Used by
/// the admin "Encryption activity" view. The (conv_id, completed_at
/// DESC) index covers this query so pagination is cheap.
pub async fn list_for_conversation(
    pool: &PgPool,
    conversation_id: Uuid,
    limit: i64,
) -> Result<Vec<GroupKeyRotationRow>, sqlx::Error> {
    sqlx::query_as::<_, GroupKeyRotationRow>(
        "SELECT id, conversation_id, triggered_by_user_id, triggered_by_event, \
                key_version, completed_at, completed_by_user_id \
         FROM group_key_rotations \
         WHERE conversation_id = $1 \
         ORDER BY completed_at DESC \
         LIMIT $2",
    )
    .bind(conversation_id)
    .bind(limit)
    .fetch_all(pool)
    .await
}
