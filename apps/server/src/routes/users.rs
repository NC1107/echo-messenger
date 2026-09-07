//! User profile endpoints: avatar upload and serving.

use axum::Json;
use axum::body::Body;
use axum::extract::{Multipart, Path, Query, State};
use axum::http::HeaderMap;
use axum::http::StatusCode;
use axum::http::header::{CACHE_CONTROL, CONTENT_TYPE, ETAG, IF_NONE_MATCH};
use axum::response::{IntoResponse, Response};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde::Serialize;
use serde_json::json;
use std::sync::Arc;
use tokio::fs;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::db;
use crate::error::{AppError, DbErrCtx, ErrorCode};

use super::AppState;

#[derive(Serialize)]
pub struct UserProfile {
    pub user_id: Uuid,
    pub username: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    pub bio: Option<String>,
    pub status_message: Option<String>,
    pub timezone: Option<String>,
    pub pronouns: Option<String>,
    pub website: Option<String>,
    pub email: Option<String>,
    pub phone: Option<String>,
    pub background_color: Option<String>,
    pub location: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Deserialize)]
pub struct UpdateProfileRequest {
    pub display_name: Option<String>,
    pub bio: Option<String>,
    pub status_message: Option<String>,
    pub timezone: Option<String>,
    pub pronouns: Option<String>,
    pub website: Option<String>,
    pub email: Option<String>,
    pub phone: Option<String>,
    pub background_color: Option<String>,
    pub location: Option<String>,
}

#[derive(Serialize)]
pub struct PrivacyPreferencesResponse {
    pub read_receipts_enabled: bool,
    pub allow_unencrypted_dm: bool,
    pub email_visible: bool,
    pub phone_visible: bool,
    pub email_discoverable: bool,
    pub phone_discoverable: bool,
    pub searchable: bool,
}

#[derive(Deserialize)]
pub struct UpdatePrivacyPreferencesRequest {
    pub read_receipts_enabled: Option<bool>,
    pub allow_unencrypted_dm: Option<bool>,
    pub email_visible: Option<bool>,
    pub phone_visible: Option<bool>,
    pub email_discoverable: Option<bool>,
    pub phone_discoverable: Option<bool>,
    pub searchable: Option<bool>,
}

/// GET /api/users/me/privacy
pub async fn get_my_privacy(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, AppError> {
    let privacy = db::users::get_privacy_preferences(&state.pool, auth.user_id)
        .await
        .db_ctx("get_my_privacy")?
        .ok_or_else(|| AppError::not_found("User not found"))?;

    Ok(Json(PrivacyPreferencesResponse {
        read_receipts_enabled: privacy.read_receipts_enabled,
        allow_unencrypted_dm: false,
        email_visible: privacy.email_visible,
        phone_visible: privacy.phone_visible,
        email_discoverable: privacy.email_discoverable,
        phone_discoverable: privacy.phone_discoverable,
        searchable: privacy.searchable,
    }))
}

/// PATCH /api/users/me/privacy
///
/// TD-51: single-statement partial update. Unset fields keep their current
/// value via `COALESCE`, eliminating the read-modify-write race the old
/// implementation had — two concurrent PATCHes from different devices could
/// lose fields between the SELECT and the UPDATE; this path has no such
/// window.
pub async fn update_my_privacy(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(payload): Json<UpdatePrivacyPreferencesRequest>,
) -> Result<impl IntoResponse, AppError> {
    let updated = db::users::update_privacy_preferences_partial(
        &state.pool,
        auth.user_id,
        db::users::PrivacyPartial {
            read_receipts_enabled: payload.read_receipts_enabled,
            email_visible: payload.email_visible,
            phone_visible: payload.phone_visible,
            email_discoverable: payload.email_discoverable,
            phone_discoverable: payload.phone_discoverable,
            searchable: payload.searchable,
        },
    )
    .await
    .db_ctx("update_my_privacy")?
    .ok_or_else(|| AppError::not_found("User not found"))?;

    Ok(Json(PrivacyPreferencesResponse {
        read_receipts_enabled: updated.read_receipts_enabled,
        allow_unencrypted_dm: false,
        email_visible: updated.email_visible,
        phone_visible: updated.phone_visible,
        email_discoverable: updated.email_discoverable,
        phone_discoverable: updated.phone_discoverable,
        searchable: updated.searchable,
    }))
}

/// GET /api/users/:id/profile
///
/// Returns the public profile for a user.
pub async fn get_profile(
    _auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(user_id): Path<Uuid>,
) -> Result<impl IntoResponse, AppError> {
    let profile = db::users::find_public_profile(&state.pool, user_id)
        .await
        .db_ctx("get_profile")?
        .ok_or_else(|| AppError::not_found("User not found"))?;

    Ok(Json(UserProfile {
        user_id: profile.id,
        username: profile.username,
        display_name: profile.display_name,
        avatar_url: profile.avatar_url,
        bio: profile.bio,
        status_message: profile.status_message,
        timezone: profile.timezone,
        pronouns: profile.pronouns,
        website: profile.website,
        email: profile.email,
        phone: profile.phone,
        background_color: profile.background_color,
        location: profile.location,
        created_at: profile.created_at,
    }))
}

/// Validate the optional profile fields. Extracted from [`update_profile`] and
/// table-driven for the simple length limits so the cognitive complexity stays
/// in budget (S3776). Returns the first violation as a 400, matching the prior
/// inline order closely enough for single-field callers.
fn validate_profile_fields(body: &UpdateProfileRequest) -> Result<(), AppError> {
    // (value, max length, message) for the plain max-length fields.
    let length_limits: [(Option<&str>, usize, &str); 8] = [
        (
            body.display_name.as_deref(),
            50,
            "Display name must be 50 characters or less",
        ),
        (
            body.bio.as_deref(),
            300,
            "Bio must be 300 characters or less",
        ),
        (
            body.status_message.as_deref(),
            100,
            "Status message must be 100 characters or less",
        ),
        (
            body.pronouns.as_deref(),
            30,
            "Pronouns must be 30 characters or less",
        ),
        (
            body.website.as_deref(),
            200,
            "Website must be 200 characters or less",
        ),
        (
            body.email.as_deref(),
            254,
            "Email must be 254 characters or less",
        ),
        (
            body.phone.as_deref(),
            30,
            "Phone must be 30 characters or less",
        ),
        (
            body.location.as_deref(),
            80,
            "Location must be 80 characters or less",
        ),
    ];
    for (value, max, msg) in length_limits {
        if let Some(v) = value
            && v.len() > max
        {
            return Err(AppError::bad_request(msg));
        }
    }

    if let Some(email) = body.email.as_deref()
        && !email.is_empty()
        && !email.contains('@')
    {
        return Err(AppError::bad_request("Email must contain an @ symbol"));
    }
    if let Some(phone) = body.phone.as_deref()
        && !phone.is_empty()
        && !phone
            .chars()
            .all(|c| c.is_ascii_digit() || c == '+' || c == '-' || c == ' ')
    {
        return Err(AppError::bad_request(
            "Phone must contain only digits, +, -, or spaces",
        ));
    }
    if let Some(color) = body.background_color.as_deref()
        && !color.is_empty()
    {
        // Strict #RRGGBB. Front-end constrains to a preset palette, but we
        // re-validate so callers using the raw API can't inject CSS.
        let valid = color.len() == 7
            && color.starts_with('#')
            && color[1..].chars().all(|c| c.is_ascii_hexdigit());
        if !valid {
            return Err(AppError::bad_request(
                "background_color must be a #RRGGBB hex string",
            ));
        }
    }
    Ok(())
}

/// PATCH /api/users/me/profile
///
/// Update the authenticated user's profile fields. All fields are optional;
/// only provided fields are updated.
pub async fn update_profile(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(body): Json<UpdateProfileRequest>,
) -> Result<impl IntoResponse, AppError> {
    validate_profile_fields(&body)?;

    // Normalize phone to E.164: strip all non-digit chars except leading +.
    let normalized_phone = body.phone.as_deref().map(|p| {
        if p.is_empty() {
            String::new()
        } else {
            p.chars()
                .filter(|c| c.is_ascii_digit() || *c == '+')
                .collect::<String>()
        }
    });

    let fields = db::users::ProfileUpdate {
        display_name: body.display_name.as_deref(),
        bio: body.bio.as_deref(),
        status_message: body.status_message.as_deref(),
        timezone: body.timezone.as_deref(),
        pronouns: body.pronouns.as_deref(),
        website: body.website.as_deref(),
        email: body.email.as_deref(),
        phone: normalized_phone.as_deref(),
        background_color: body.background_color.as_deref(),
        location: body.location.as_deref(),
    };
    let profile = db::users::update_profile(&state.pool, auth.user_id, &fields)
        .await
        .db_ctx("update_profile")?;

    Ok(Json(UserProfile {
        user_id: profile.id,
        username: profile.username,
        display_name: profile.display_name,
        avatar_url: profile.avatar_url,
        bio: profile.bio,
        status_message: profile.status_message,
        timezone: profile.timezone,
        pronouns: profile.pronouns,
        website: profile.website,
        email: profile.email,
        phone: profile.phone,
        background_color: profile.background_color,
        location: profile.location,
        created_at: profile.created_at,
    }))
}

/// PATCH /api/users/me/status
///
/// Update the authenticated user's presence status. Accepted values:
/// "online", "away", "dnd", "invisible".
///
/// Broadcasting is handled here: invisible users are announced as "offline"
/// to contacts; all other statuses propagate their value.
pub async fn update_presence_status(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(body): Json<UpdatePresenceStatusRequest>,
) -> Result<impl IntoResponse, AppError> {
    let valid = ["online", "away", "dnd", "invisible"];
    if !valid.contains(&body.status.as_str()) {
        return Err(AppError::bad_request(
            "status must be one of: online, away, dnd, invisible",
        ));
    }

    db::users::update_presence_status(&state.pool, auth.user_id, &body.status)
        .await
        .db_ctx("update_presence_status")?;

    // Broadcast to contacts.  Invisible users appear offline to others.
    let broadcast_status = if body.status == "invisible" {
        "offline"
    } else {
        &body.status
    };

    // Fetch username for the presence payload.
    let user = db::users::find_by_id(&state.pool, auth.user_id)
        .await
        .db_ctx("update_presence_status/find_user")?
        .ok_or_else(|| AppError::internal("User not found"))?;

    broadcast_presence_with_status(
        &state,
        auth.user_id,
        &user.username,
        broadcast_status,
        &body.status,
    )
    .await;

    Ok(Json(json!({ "status": body.status })))
}

#[derive(Deserialize)]
pub struct UpdatePresenceStatusRequest {
    pub status: String,
}

/// Broadcast a presence event to all contacts.
///
/// `broadcast_status` is what contacts see ("online"/"away"/"dnd"/"offline");
/// `presence_status` is the raw stored value ("online"/"away"/"dnd"/"invisible").
async fn broadcast_presence_with_status(
    state: &AppState,
    user_id: Uuid,
    username: &str,
    broadcast_status: &str,
    presence_status: &str,
) {
    use axum::extract::ws::Message as WsMessage;

    let contact_ids = match db::contacts::list_contact_user_ids(&state.pool, user_id).await {
        Ok(ids) => ids,
        Err(e) => {
            tracing::warn!("Failed to fetch contacts for presence broadcast: {e}");
            return;
        }
    };

    // Privacy: stored "invisible" must surface as "offline" — leaking the raw
    // value would let a patched client defeat invisibility.
    let hide_presence_status = presence_status == "invisible" && broadcast_status == "offline";

    let presence = if hide_presence_status {
        serde_json::json!({
            "type": "presence",
            "user_id": user_id,
            "username": username,
            "status": broadcast_status,
        })
    } else {
        serde_json::json!({
            "type": "presence",
            "user_id": user_id,
            "username": username,
            "status": broadcast_status,
            "presence_status": presence_status,
        })
    };
    if let Ok(json) = serde_json::to_string(&presence) {
        for cid in &contact_ids {
            state.hub.send_to(cid, WsMessage::Text(json.clone().into()));
        }
    }
}

/// DELETE /api/users/me
///
/// Deletes the authenticated user's account. Revokes all refresh tokens first,
/// then deletes the user row (FK CASCADE handles contacts, messages, etc.).
pub async fn delete_account(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, AppError> {
    // Revoke all refresh tokens
    db::tokens::revoke_all_user_tokens(&state.pool, auth.user_id)
        .await
        .db_ctx("delete_account/revoke_tokens")?;

    // Disconnect from WebSocket hub if online
    state.hub.unregister_all(auth.user_id);

    // Delete user row (CASCADE handles related tables)
    let deleted = db::users::delete_user(&state.pool, auth.user_id)
        .await
        .db_ctx("delete_account/delete_user")?;

    if !deleted {
        return Err(AppError::internal("User not found"));
    }

    // Clean up avatar files from disk
    for ext in &["jpg", "png", "webp", "gif"] {
        let path = format!("./uploads/avatars/{}.{}", auth.user_id, ext);
        let _ = fs::remove_file(&path).await;
    }

    Ok(StatusCode::NO_CONTENT)
}

/// PATCH /api/users/me/password
///
/// Change the authenticated user's password. Requires the current password
/// for verification and a new password that meets the minimum length.
pub async fn change_password(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(body): Json<ChangePasswordRequest>,
) -> Result<impl IntoResponse, AppError> {
    use crate::auth::password;

    if body.new_password.len() < 8 || body.new_password.len() > 128 {
        return Err(AppError::bad_request(
            "New password must be 8-128 characters",
        ));
    }

    // Verify current password
    let user = db::users::find_by_id(&state.pool, auth.user_id)
        .await
        .db_ctx("change_password/find_user")?
        .ok_or_else(|| AppError::not_found("User not found"))?;

    // spawn_blocking: Argon2 verify is 50-150ms CPU — keep tokio workers free.
    let stored_hash = user.password_hash.clone();
    let current_password = body.current_password.clone();
    let valid = tokio::task::spawn_blocking(move || {
        password::verify_password(&current_password, &stored_hash)
    })
    .await
    .map_err(|e| AppError::internal(format!("argon2 join error: {e}")))??;
    if !valid {
        return Err(AppError::unauthorized("Current password is incorrect"));
    }

    // Hash and store new password (also spawn_blocking, same reason).
    let new_password = body.new_password.clone();
    let new_hash = tokio::task::spawn_blocking(move || password::hash_password(&new_password))
        .await
        .map_err(|e| AppError::internal(format!("argon2 join error: {e}")))??;
    db::users::update_password(&state.pool, auth.user_id, &new_hash)
        .await
        .db_ctx("change_password/update")?;

    // Revoke all refresh tokens so other sessions are logged out
    db::tokens::revoke_all_user_tokens(&state.pool, auth.user_id)
        .await
        .db_ctx("change_password/revoke_tokens")?;

    // CR-4: also invalidate outstanding 15-minute access tokens so a
    // compromised session is killed immediately, not at JWT TTL.
    state.token_invalidator.invalidate(auth.user_id);

    Ok(Json(json!({ "status": "password_changed" })))
}

#[derive(Deserialize)]
pub struct ChangePasswordRequest {
    pub current_password: String,
    pub new_password: String,
}

/// GET /api/users/online
///
/// Returns the list of currently connected user IDs, filtered to the
/// caller's contacts only (prevents platform-wide user enumeration).
pub async fn online_users(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, AppError> {
    let contact_ids = db::contacts::list_contact_user_ids(&state.pool, auth.user_id)
        .await
        .db_ctx("online_users/list_contacts")?;
    let all_online = state.hub.get_online_user_ids();
    let online_contacts: Vec<_> = all_online
        .into_iter()
        .filter(|id| contact_ids.contains(id))
        .collect();
    Ok(Json(
        serde_json::json!({ "online_user_ids": online_contacts }),
    ))
}

/// GET /api/users/search?q=<query>
///
/// Search users by username prefix. Returns up to 10 public profile results.
pub async fn search_users(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Query(params): Query<UserSearchQuery>,
) -> Result<impl IntoResponse, AppError> {
    let query = params.q.trim();
    if query.is_empty() || query.len() < 2 {
        return Ok(Json(serde_json::json!({ "users": [] })));
    }

    let results = db::users::search_users(&state.pool, query, auth.user_id)
        .await
        .db_ctx("search_users")?;

    let users: Vec<_> = results
        .into_iter()
        .map(|p| {
            serde_json::json!({
                "user_id": p.id,
                "username": p.username,
                "display_name": p.display_name,
                "avatar_url": p.avatar_url,
            })
        })
        .collect();

    Ok(Json(serde_json::json!({ "users": users })))
}

#[derive(Deserialize)]
pub struct UserSearchQuery {
    #[serde(default)]
    pub q: String,
}

#[derive(Serialize)]
pub struct UsernameInviteResolutionResponse {
    pub user_id: Uuid,
    pub username: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    pub bio: Option<String>,
    pub status_message: Option<String>,
    pub relationship: String,
}

/// GET /api/users/resolve/:username
///
/// Resolve a username for DM invite links, enforcing searchable privacy for
/// users with no existing relationship.
pub async fn resolve_username_invite(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(username): Path<String>,
) -> Result<impl IntoResponse, AppError> {
    let candidate = username.trim();
    if candidate.is_empty() {
        return Err(AppError::not_found("User not found"));
    }

    let resolved = db::users::resolve_username_invite(&state.pool, auth.user_id, candidate)
        .await
        .db_ctx("resolve_username_invite")?
        .ok_or_else(|| AppError::not_found("User not found"))?;

    let discoverable = resolved.searchable
        || resolved.relationship == "contact"
        || resolved.relationship == "pending"
        || resolved.relationship == "blocked";
    if !discoverable {
        return Err(AppError::not_found("User not found"));
    }

    Ok(Json(UsernameInviteResolutionResponse {
        user_id: resolved.id,
        username: resolved.username,
        display_name: resolved.display_name,
        avatar_url: resolved.avatar_url,
        bio: resolved.bio,
        status_message: resolved.status_message,
        relationship: resolved.relationship,
    }))
}

/// Maximum avatar size: 2 MB.
pub(super) const MAX_AVATAR_SIZE: usize = 2 * 1024 * 1024;

/// Allowed avatar MIME types (validated via magic bytes, not client-supplied Content-Type).
const ALLOWED_AVATAR_TYPES: &[&str] = &["image/jpeg", "image/png", "image/webp", "image/gif"];

/// Derive a file extension from a MIME type.
fn extension_for_mime(mime: &str) -> &str {
    match mime {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/webp" => "webp",
        "image/gif" => "gif",
        _ => "bin",
    }
}

/// Guess MIME type from file extension.
fn mime_for_extension(ext: &str) -> &str {
    match ext {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "webp" => "image/webp",
        "gif" => "image/gif",
        _ => "application/octet-stream",
    }
}

/// Stream a multipart `field` into memory, rejecting the moment its byte
/// total crosses `max_bytes`.  Avatars are capped at a few MB so the whole
/// buffer is still small enough for `infer::get` validation, but the
/// previous `field.bytes().await` path read the entire client-supplied
/// payload into RAM before checking the cap (#831).  This helper closes
/// that DoS window — concurrent attackers can no longer pin O(N * 100 MB)
/// of process memory by spamming oversized POSTs.
///
/// Shared by both `/me/avatar` and `/groups/{id}/avatar` upload handlers.
pub(super) async fn read_avatar_field_capped(
    mut field: axum::extract::multipart::Field<'_>,
    max_bytes: usize,
) -> Result<Vec<u8>, AppError> {
    let mut buf = Vec::with_capacity(max_bytes.min(64 * 1024));
    loop {
        let chunk = field
            .chunk()
            .await
            .map_err(|e| AppError::bad_request(format!("Failed to read avatar data: {e}")))?;
        let Some(bytes) = chunk else { break };
        if bytes.is_empty() {
            continue;
        }
        if buf.len().saturating_add(bytes.len()) > max_bytes {
            return Err(AppError::bad_request(format!(
                "Avatar too large. Maximum size is {max_bytes} bytes"
            )));
        }
        buf.extend_from_slice(&bytes);
    }
    Ok(buf)
}

/// PUT /api/users/me/avatar
///
/// Accepts multipart form data with an `avatar` field.
/// Validates the file type via magic bytes (ignores client-supplied Content-Type).
/// Saves the file to `./uploads/avatars/{user_id}.{ext}` and updates the user record.
pub async fn upload_avatar(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    mut multipart: Multipart,
) -> Result<impl IntoResponse, AppError> {
    fs::create_dir_all("./uploads/avatars")
        .await
        .map_err(|e| AppError::internal(format!("Failed to create avatars directory: {e}")))?;

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| AppError::bad_request(format!("Invalid multipart data: {e}")))?
    {
        // Accept "avatar" (historical) or "file" (matches /api/media/upload).
        let field_name = field.name().unwrap_or_default().to_string();
        if field_name != "avatar" && field_name != "file" {
            continue;
        }

        let data = read_avatar_field_capped(field, MAX_AVATAR_SIZE).await?;

        // Validate via magic bytes, not client-declared Content-Type.
        let mime_type = match infer::get(&data) {
            Some(inferred) => inferred.mime_type().to_string(),
            None => {
                return Err(AppError::with_code(
                    ErrorCode::UnsupportedMediaType,
                    "Could not determine avatar file type from content",
                ));
            }
        };

        if !ALLOWED_AVATAR_TYPES.contains(&mime_type.as_str()) {
            return Err(AppError::with_code(
                ErrorCode::UnsupportedMediaType,
                format!(
                    "Avatar type '{mime_type}' is not allowed. \
                     Allowed: {}",
                    ALLOWED_AVATAR_TYPES.join(", ")
                ),
            ));
        }

        let ext = extension_for_mime(&mime_type);
        let disk_filename = format!("{}.{}", auth.user_id, ext);
        let disk_path = format!("./uploads/avatars/{disk_filename}");

        // Remove any old avatar files for this user (different extensions)
        for old_ext in &["jpg", "png", "webp", "gif"] {
            let old_path = format!("./uploads/avatars/{}.{}", auth.user_id, old_ext);
            let _ = fs::remove_file(&old_path).await;
        }

        fs::write(&disk_path, &data)
            .await
            .map_err(|e| AppError::internal(format!("Failed to save avatar: {e}")))?;

        let avatar_url = format!("/api/users/{}/avatar", auth.user_id);
        db::users::set_avatar_url(&state.pool, auth.user_id, &avatar_url).await?;

        return Ok((
            StatusCode::OK,
            axum::Json(json!({ "avatar_url": avatar_url })),
        ));
    }

    Err(AppError::bad_request(
        "Missing avatar in multipart form data (expected field name 'avatar' or 'file')",
    ))
}

/// Build a weak ETag from the file's size + modification time.
///
/// `W/"<size>-<mtime_secs>"` — collision risk is "two different files with
/// identical size and identical mtime in the same second", which a CDN /
/// browser cache can tolerate. The strong-validator alternative would
/// require hashing the bytes on every read; we'd rather avoid that for
/// frequently-fetched assets like avatars.
fn weak_etag(meta: &std::fs::Metadata) -> String {
    let mtime_secs = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("W/\"{}-{}\"", meta.len(), mtime_secs)
}

/// `Cache-Control` value used for public, mostly-immutable media (avatars,
/// uploaded images). 5 min fresh + 1 day stale-while-revalidate keeps the
/// chat list snappy without making bust scenarios painful.
const MEDIA_CACHE_CONTROL: &str = "public, max-age=300, stale-while-revalidate=86400";

/// GET /api/users/:id/avatar
///
/// Serves the avatar image with the correct Content-Type header.
/// Public endpoint — no auth required (avatars are profile pictures).
/// Returns 404 if no avatar is set.
///
/// TD-39: emits `Cache-Control` + a weak `ETag` derived from (size, mtime)
/// and honors `If-None-Match` → 304. Cuts the typical chat-list render
/// from 50 disk reads to ~0 once the cache warms up.
pub async fn get_avatar(
    State(state): State<Arc<AppState>>,
    Path(user_id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    // Verify user has an avatar_url set
    let avatar_url = db::users::get_avatar_url(&state.pool, user_id)
        .await?
        .ok_or_else(|| AppError {
            status: StatusCode::NOT_FOUND,
            message: "No avatar set for this user".to_string(),
            code: ErrorCode::NotFound,
            body: None,
        })?;

    // Ensure the avatar_url actually points to this user
    let expected_prefix = format!("/api/users/{}/avatar", user_id);
    if avatar_url != expected_prefix {
        return Err(AppError {
            status: StatusCode::NOT_FOUND,
            message: "No avatar set for this user".to_string(),
            code: ErrorCode::NotFound,
            body: None,
        });
    }

    // Try to find the avatar file on disk
    for ext in &["jpg", "png", "webp", "gif"] {
        let disk_path = format!("./uploads/avatars/{}.{}", user_id, ext);
        let Ok(meta) = fs::metadata(&disk_path).await else {
            continue;
        };
        let etag = weak_etag(&meta);

        // Honor If-None-Match → 304 Not Modified without reading the file.
        if let Some(inm) = headers.get(IF_NONE_MATCH).and_then(|v| v.to_str().ok())
            && etag_matches(inm, &etag)
        {
            return Response::builder()
                .status(StatusCode::NOT_MODIFIED)
                .header(CACHE_CONTROL, MEDIA_CACHE_CONTROL)
                .header(ETAG, &etag)
                .body(Body::empty())
                .map_err(|e| AppError::internal(format!("Failed to build response: {e}")));
        }

        let Ok(data) = fs::read(&disk_path).await else {
            continue;
        };
        let mime = mime_for_extension(ext);
        let response = Response::builder()
            .status(StatusCode::OK)
            .header(CONTENT_TYPE, mime)
            .header(CACHE_CONTROL, MEDIA_CACHE_CONTROL)
            .header(ETAG, &etag)
            .body(Body::from(data))
            .map_err(|e| AppError::internal(format!("Failed to build response: {e}")))?;
        return Ok(response);
    }

    Err(AppError {
        status: StatusCode::NOT_FOUND,
        message: "Avatar file not found on disk".to_string(),
        code: ErrorCode::NotFound,
        body: None,
    })
}

/// Match an `If-None-Match` header value against our emitted ETag.
///
/// Honors the comma-separated list form (`"abc", "def"`) and the wildcard
/// `*`. Comparison treats weak (`W/"x"`) and strong (`"x"`) forms as equal
/// because we only ever emit weak validators.
fn etag_matches(inm: &str, ours: &str) -> bool {
    let normalize = |t: &str| {
        t.trim()
            .trim_start_matches("W/")
            .trim_matches('"')
            .to_string()
    };
    let ours_norm = normalize(ours);
    inm.split(',').any(|tok| {
        let t = tok.trim();
        t == "*" || normalize(t) == ours_norm
    })
}

#[derive(Deserialize)]
pub struct UpdateStatusTextRequest {
    pub status_text: Option<String>,
}

/// PUT /api/users/me/status-text
pub async fn update_status_text(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(body): Json<UpdateStatusTextRequest>,
) -> Result<impl IntoResponse, AppError> {
    let text = body
        .status_text
        .as_deref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty());
    // Enforce max length at the route boundary.
    if let Some(t) = text
        && t.len() > 64
    {
        return Err(AppError::bad_request(
            "status_text must be 64 characters or fewer",
        ));
    }
    db::users::update_status_text(&state.pool, auth.user_id, text)
        .await
        .db_ctx("update_status_text")?;
    Ok(StatusCode::NO_CONTENT)
}
