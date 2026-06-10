//! Group encryption key REST endpoints.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::{AppError, DbErrCtx};
use crate::types::Role;

use super::AppState;

// -------------------------------------------------------------------------
// Request / response types
// -------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct KeyEnvelope {
    pub user_id: Uuid,
    pub encrypted_key: String,
}

#[derive(Debug, Deserialize)]
pub struct UploadGroupKeyRequest {
    /// The version number for this key (must be higher than any existing).
    pub key_version: i32,
    /// Per-member encrypted envelopes. Each contains the group AES key
    /// encrypted specifically for that member using their identity public key.
    pub envelopes: Vec<KeyEnvelope>,
    /// Minimum on-wire group-message format version that receivers will
    /// accept against this key version. Defaults to 1 (GRP1 + GRP2 both
    /// accepted) for backwards compatibility. GRP2-capable rotators
    /// should send 2 to lock the receiver into the signature-bearing
    /// wire format and close the downgrade-attack vector described in
    /// `docs/group-e2e-design/04-migration-plan.md`.
    #[serde(default = "default_min_wire_version")]
    pub min_wire_version: i16,
    /// Free-form reason the rotator fired. Persisted into the
    /// `group_key_rotations` audit log so admins can see whether a
    /// rotation came from a membership change, an explicit
    /// "encryption activity → rotate" press, or the first-key flow.
    /// Values are stored verbatim; callers should pick from the
    /// documented vocabulary (`first_key`, `explicit_rotate`,
    /// `membership_change`, `kick`, `leave`, `rekey_after_compromise`)
    /// but the server doesn't enforce the enum so future event types
    /// don't need a schema migration. Defaults to `unspecified` when
    /// the caller doesn't send a value — that lets pre-Phase-3
    /// clients keep working without lying about the reason.
    #[serde(default = "default_triggered_by_event")]
    pub triggered_by_event: String,
}

fn default_min_wire_version() -> i16 {
    1
}

fn default_triggered_by_event() -> String {
    "unspecified".to_string()
}

#[derive(Debug, Serialize)]
pub struct GroupKeyResponse {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub key_version: i32,
    pub encrypted_key: String,
    pub created_by: Uuid,
    pub created_at: String,
}

impl GroupKeyResponse {
    fn from_row(row: db::keys::GroupKeyRow) -> Self {
        Self {
            id: row.id,
            conversation_id: row.conversation_id,
            key_version: row.key_version,
            encrypted_key: row.encrypted_key,
            created_by: row.created_by,
            created_at: row.created_at.to_rfc3339(),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct GroupKeyEnvelopeResponse {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub key_version: i32,
    pub encrypted_key: String,
    /// Minimum on-wire format version the rotator pinned for this key —
    /// see [`UploadGroupKeyRequest::min_wire_version`]. Defaults to 1.
    /// Receivers must refuse incoming messages whose wire prefix is
    /// older than this value at this key version.
    pub min_wire_version: i16,
    pub created_at: String,
}

impl GroupKeyEnvelopeResponse {
    fn from_row(row: db::keys::GroupKeyEnvelopeRow) -> Self {
        Self {
            id: row.id,
            conversation_id: row.conversation_id,
            key_version: row.key_version,
            encrypted_key: row.encrypted_key,
            min_wire_version: row.min_wire_version,
            created_at: row.created_at.to_rfc3339(),
        }
    }
}

// -------------------------------------------------------------------------
// POST /api/groups/:id/keys -- Upload group key envelopes (owner/admin only)
// -------------------------------------------------------------------------

/// Cap envelope count so a hostile admin can't pollute the table.
const MAX_ENVELOPES_PER_REQUEST: usize = 10_000;
/// Each envelope is a wrapped 32-byte AES-256 key (~124 base64 chars in
/// practice). 512 bytes is generous headroom while blocking abuse —
/// without this cap, a single 10K-envelope request could write up to
/// ~10 GB of attacker-controlled TEXT.
const MAX_ENCRYPTED_KEY_LEN: usize = 512;
/// Audit reason string — bounded so a malicious admin can't write
/// arbitrarily large blobs into the audit log that other admins
/// re-download on every /encryption-activity GET.
const MAX_TRIGGERED_BY_EVENT_LEN: usize = 128;

/// Validates the body of an [`upload_group_key`] request. Extracted so the
/// route handler stays under SonarCloud's cognitive-complexity threshold.
fn validate_upload_request(body: &UploadGroupKeyRequest) -> Result<(), AppError> {
    if body.envelopes.is_empty() {
        return Err(AppError::bad_request("envelopes array cannot be empty"));
    }
    if body.key_version < 1 {
        return Err(AppError::bad_request(
            "key_version must be a positive integer",
        ));
    }
    // Mirror the column CHECK (1..=255) so clients see 400 not 23514.
    if !(1..=255).contains(&body.min_wire_version) {
        return Err(AppError::bad_request(
            "min_wire_version must be between 1 and 255",
        ));
    }
    if body.envelopes.len() > MAX_ENVELOPES_PER_REQUEST {
        return Err(AppError::bad_request(format!(
            "Too many envelopes (max {MAX_ENVELOPES_PER_REQUEST})"
        )));
    }
    if body.triggered_by_event.len() > MAX_TRIGGERED_BY_EVENT_LEN {
        return Err(AppError::bad_request(format!(
            "triggered_by_event must be ≤{MAX_TRIGGERED_BY_EVENT_LEN} characters"
        )));
    }
    for envelope in &body.envelopes {
        if envelope.encrypted_key.is_empty() {
            return Err(AppError::bad_request(
                "encrypted_key cannot be empty in envelope",
            ));
        }
        if envelope.encrypted_key.len() > MAX_ENCRYPTED_KEY_LEN {
            return Err(AppError::bad_request(format!(
                "encrypted_key must be ≤{MAX_ENCRYPTED_KEY_LEN} bytes"
            )));
        }
    }
    Ok(())
}

/// Authorise the caller as an admin (or above) of the group. Extracted
/// from [`upload_group_key`] to keep the handler's cognitive complexity
/// under the lint threshold.
async fn require_admin_or_above(
    state: &AppState,
    group_id: Uuid,
    user_id: Uuid,
) -> Result<(), AppError> {
    let role_str = db::groups::get_member_role(&state.pool, group_id, user_id)
        .await
        .db_ctx("upload_group_key/get_role")?
        .ok_or_else(|| AppError::forbidden("Not a member of this group"))?;

    let role = Role::from_str_opt(&role_str).unwrap_or(Role::Member);
    if !role.is_admin_or_above() {
        return Err(AppError::forbidden(
            "Only admins and owners can upload group keys",
        ));
    }
    Ok(())
}

/// Confirm every envelope's `user_id` is a current member of the group.
/// Reads the member set inside the caller's transaction so the view
/// matches the writes that follow.
async fn ensure_envelopes_target_members(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    group_id: Uuid,
    envelopes: &[KeyEnvelope],
) -> Result<(), AppError> {
    let member_ids: std::collections::HashSet<Uuid> =
        db::groups::get_conversation_member_ids(&mut **tx, group_id)
            .await
            .db_ctx("upload_group_key/members")?
            .into_iter()
            .collect();

    for envelope in envelopes {
        if !member_ids.contains(&envelope.user_id) {
            return Err(AppError::bad_request(format!(
                "envelope user_id {} is not a member of this group",
                envelope.user_id
            )));
        }
    }
    Ok(())
}

/// Map the `store_group_key` DB error to an [`AppError`]. A unique-violation
/// (`23505`) on the sentinel row maps to 409 Conflict; everything else is
/// an opaque 500 with the underlying error logged.
fn map_store_group_key_error(e: sqlx::Error) -> AppError {
    match &e {
        sqlx::Error::Database(db_err) if db_err.code().as_deref() == Some("23505") => {
            AppError::conflict("A group key with this version already exists")
        }
        _ => {
            tracing::error!("DB error in upload_group_key/store: {e:?}");
            AppError::internal("Failed to store group key")
        }
    }
}

/// Write the sentinel row, every per-member envelope, and the audit row
/// in a single transaction so the rotation lands atomically. Returns the
/// newly-stored sentinel row for the response payload.
async fn persist_group_key_and_envelopes(
    state: &AppState,
    group_id: Uuid,
    auth_user_id: Uuid,
    body: &UploadGroupKeyRequest,
) -> Result<db::keys::GroupKeyRow, AppError> {
    let mut tx = state.pool.begin().await.db_ctx("upload_group_key/begin")?;

    ensure_envelopes_target_members(&mut tx, group_id, &body.envelopes).await?;

    // Store a sentinel row in group_keys for version tracking (encrypted_key
    // is a placeholder -- the real per-member keys live in group_key_envelopes).
    let row = db::keys::store_group_key(
        &mut *tx,
        group_id,
        body.key_version,
        "__envelope__",
        auth_user_id,
    )
    .await
    .map_err(map_store_group_key_error)?;

    // All envelopes at a given key_version share min_wire_version — per-member
    // differences would let a hostile rotator pin one recipient on GRP1.
    for envelope in &body.envelopes {
        db::keys::store_group_key_envelope(
            &mut *tx,
            group_id,
            body.key_version,
            envelope.user_id,
            &envelope.encrypted_key,
            body.min_wire_version,
        )
        .await
        .db_ctx("upload_group_key/store_envelope")?;
    }

    // OQ-13: audit log written in the same tx as the envelopes so they commit
    // atomically; leader election is a future enhancement.
    db::group_key_rotations::insert_completed_rotation(
        &mut *tx,
        group_id,
        auth_user_id,
        &body.triggered_by_event,
        body.key_version,
        auth_user_id,
    )
    .await
    .db_ctx("upload_group_key/audit")?;

    tx.commit().await.db_ctx("upload_group_key/commit")?;
    Ok(row)
}

/// Broadcast a `group_key_rotated` event to every member of the group and
/// also echo it back to the uploader so their client caches the new version.
async fn broadcast_key_rotated(
    state: &AppState,
    group_id: Uuid,
    auth_user_id: Uuid,
    key_version: i32,
) {
    let member_ids = db::groups::get_conversation_member_ids(&state.pool, group_id)
        .await
        .unwrap_or_default();

    let event = serde_json::json!({
        "type": "group_key_rotated",
        "conversation_id": group_id,
        "key_version": key_version,
        "created_by": auth_user_id,
    });
    if let Ok(json) = serde_json::to_string(&event) {
        use axum::extract::ws::Message as WsMessage;
        state
            .hub
            .broadcast_json(&member_ids, &json, Some(auth_user_id));
        // Also notify the uploader so their client caches the new version
        state
            .hub
            .send_to(&auth_user_id, WsMessage::Text(json.into()));
    }
}

pub async fn upload_group_key(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
    Json(body): Json<UploadGroupKeyRequest>,
) -> Result<impl IntoResponse, AppError> {
    require_admin_or_above(&state, group_id, auth.user_id).await?;
    validate_upload_request(&body)?;

    let row = persist_group_key_and_envelopes(&state, group_id, auth.user_id, &body).await?;

    broadcast_key_rotated(&state, group_id, auth.user_id, row.key_version).await;

    Ok((StatusCode::CREATED, Json(GroupKeyResponse::from_row(row))))
}

// -------------------------------------------------------------------------
// GET /api/groups/:id/keys/latest -- Get latest group key envelope for me
// -------------------------------------------------------------------------

pub async fn get_latest_group_key(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let is_member = db::groups::is_member(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("get_latest_group_key/is_member")?;

    if !is_member {
        return Err(AppError::forbidden("Not a member of this group"));
    }

    // Try envelope-based lookup first (new E2E scheme)
    let envelope = db::keys::get_my_group_key_envelope(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("get_latest_group_key/envelope")?;

    if let Some(env) = envelope {
        return Ok(Json(GroupKeyEnvelopeResponse::from_row(env)).into_response());
    }

    // No envelope for caller: 400 if group has no key at all, 410 if a sentinel
    // exists (so the client can surface the "needs rotation" banner).
    let row = db::keys::get_latest_group_key(&state.pool, group_id)
        .await
        .db_ctx("get_latest_group_key/fetch")?
        .ok_or_else(|| AppError::bad_request("No group key found for this conversation"))?;

    // Sentinel = envelope distribution; non-sentinel = legacy plaintext key.
    if row.encrypted_key == "__envelope__" {
        let body = serde_json::json!({
            "error": "No group-key envelope exists for this user at the latest version",
            "code": "no-envelope-for-user",
            "key_version": row.key_version,
        });
        return Ok((StatusCode::GONE, Json(body)).into_response());
    }

    Ok(Json(GroupKeyResponse::from_row(row)).into_response())
}

// -------------------------------------------------------------------------
// GET /api/groups/:id/keys/:version -- Get a specific group key version
// -------------------------------------------------------------------------

pub async fn get_group_key_version(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path((group_id, version)): Path<(Uuid, i32)>,
) -> Result<impl IntoResponse, AppError> {
    let is_member = db::groups::is_member(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("get_group_key_version/is_member")?;

    if !is_member {
        return Err(AppError::forbidden("Not a member of this group"));
    }

    // Try envelope-based lookup first
    let envelope =
        db::keys::get_my_group_key_envelope_version(&state.pool, group_id, auth.user_id, version)
            .await
            .db_ctx("get_group_key_version/envelope")?;

    if let Some(env) = envelope {
        return Ok(Json(GroupKeyEnvelopeResponse::from_row(env)).into_response());
    }

    // Fallback: legacy group_keys table
    let row = db::keys::get_group_key(&state.pool, group_id, version)
        .await
        .db_ctx("get_group_key_version/fetch")?
        .ok_or_else(|| AppError::bad_request("Group key version not found"))?;

    Ok(Json(GroupKeyResponse::from_row(row)).into_response())
}

// -------------------------------------------------------------------------
// GET /api/groups/:id/encryption-activity -- list completed rotations
// -------------------------------------------------------------------------
// OQ-13: admin-only audit log. Rotation cadence is an operational signal an
// admin needs (malicious-admin radar) and a regular member does not.

#[derive(Debug, Serialize)]
pub struct GroupKeyRotationResponse {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub triggered_by_user_id: Uuid,
    pub triggered_by_event: String,
    pub key_version: i32,
    pub completed_at: String,
    pub completed_by_user_id: Uuid,
}

impl GroupKeyRotationResponse {
    fn from_row(row: db::group_key_rotations::GroupKeyRotationRow) -> Self {
        Self {
            id: row.id,
            conversation_id: row.conversation_id,
            triggered_by_user_id: row.triggered_by_user_id,
            triggered_by_event: row.triggered_by_event,
            key_version: row.key_version,
            completed_at: row.completed_at.to_rfc3339(),
            completed_by_user_id: row.completed_by_user_id,
        }
    }
}

pub async fn list_encryption_activity(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(group_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let role_str = db::groups::get_member_role(&state.pool, group_id, auth.user_id)
        .await
        .db_ctx("list_encryption_activity/get_role")?
        .ok_or_else(|| AppError::forbidden("Not a member of this group"))?;
    let role = Role::from_str_opt(&role_str).unwrap_or(Role::Member);
    if !role.is_admin_or_above() {
        return Err(AppError::forbidden(
            "Only admins and owners can view encryption activity",
        ));
    }

    // 100 is plenty for a UI scroll — the table is O(versions), so
    // even chatty groups land well under a page after years of life.
    let rows = db::group_key_rotations::list_for_conversation(&state.pool, group_id, 100)
        .await
        .db_ctx("list_encryption_activity/list")?;

    let body: Vec<GroupKeyRotationResponse> = rows
        .into_iter()
        .map(GroupKeyRotationResponse::from_row)
        .collect();
    Ok(Json(body))
}
