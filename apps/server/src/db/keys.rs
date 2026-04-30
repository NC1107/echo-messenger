//! PreKey bundle and group-key database queries.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use sqlx::postgres::PgConnection;
use uuid::Uuid;

#[derive(Debug, serde::Serialize)]
pub struct PreKeyBundleRow {
    pub identity_key: Vec<u8>,
    pub signing_key: Option<Vec<u8>>,
    pub signed_prekey: Vec<u8>,
    pub signed_prekey_signature: Vec<u8>,
    pub signed_prekey_id: i32,
    pub one_time_prekey: Option<OneTimePreKeyRow>,
}

#[derive(Debug, serde::Serialize)]
pub struct OneTimePreKeyRow {
    pub key_id: i32,
    pub public_key: Vec<u8>,
}

/// Fetch the canonical identity key fingerprint for a user, if one has been
/// bound. Returns `None` for users who have never uploaded a key bundle.
pub async fn get_identity_key_fingerprint(
    db: impl sqlx::PgExecutor<'_>,
    user_id: Uuid,
) -> Result<Option<Vec<u8>>, sqlx::Error> {
    let row: Option<(Option<Vec<u8>>,)> =
        sqlx::query_as("SELECT identity_key_fingerprint FROM users WHERE id = $1")
            .bind(user_id)
            .fetch_optional(db)
            .await?;
    Ok(row.and_then(|(fp,)| fp))
}

/// Bind a canonical identity key fingerprint to a user on first key upload.
pub async fn set_identity_key_fingerprint(
    db: impl sqlx::PgExecutor<'_>,
    user_id: Uuid,
    fingerprint: &[u8],
) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE users SET identity_key_fingerprint = $2 WHERE id = $1")
        .bind(user_id)
        .bind(fingerprint)
        .execute(db)
        .await?;
    Ok(())
}

/// Clear the identity key fingerprint for a user (used during key reset).
pub async fn clear_identity_key_fingerprint(
    db: impl sqlx::PgExecutor<'_>,
    user_id: Uuid,
) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE users SET identity_key_fingerprint = NULL WHERE id = $1")
        .bind(user_id)
        .execute(db)
        .await?;
    Ok(())
}

/// Fetch the identity-key fingerprint bound to a specific device, if any
/// (#664).
///
/// Falls back to `None` when the row exists but has no fingerprint yet (newly
/// uploaded device pre-binding) or the row is missing entirely.
pub async fn get_device_fingerprint(
    db: impl sqlx::PgExecutor<'_>,
    user_id: Uuid,
    device_id: i32,
) -> Result<Option<Vec<u8>>, sqlx::Error> {
    let row: Option<(Option<Vec<u8>>,)> = sqlx::query_as(
        "SELECT fingerprint FROM identity_keys WHERE user_id = $1 AND device_id = $2",
    )
    .bind(user_id)
    .bind(device_id)
    .fetch_optional(db)
    .await?;
    Ok(row.and_then(|(fp,)| fp))
}

/// Bind a fingerprint to a specific (user, device) row. Upserts so the first
/// upload after the migration writes both the identity_keys row (via
/// [`store_identity_key`]) and this fingerprint within the same transaction.
pub async fn set_device_fingerprint(
    db: impl sqlx::PgExecutor<'_>,
    user_id: Uuid,
    device_id: i32,
    fingerprint: &[u8],
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE identity_keys \
         SET fingerprint = $3, fingerprint_bound_at = NOW() \
         WHERE user_id = $1 AND device_id = $2",
    )
    .bind(user_id)
    .bind(device_id)
    .bind(fingerprint)
    .execute(db)
    .await?;
    Ok(())
}

/// Clear the per-device fingerprint binding so the next upload re-binds.
/// Used by `POST /api/keys/reset_device`.
pub async fn clear_device_fingerprint(
    db: impl sqlx::PgExecutor<'_>,
    user_id: Uuid,
    device_id: i32,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE identity_keys \
         SET fingerprint = NULL, fingerprint_bound_at = NULL \
         WHERE user_id = $1 AND device_id = $2",
    )
    .bind(user_id)
    .bind(device_id)
    .execute(db)
    .await?;
    Ok(())
}

/// Store or replace a user's identity key for a specific device.
///
/// If `platform` is provided, it is written alongside the identity keys so the
/// UI can show "iOS", "Linux", etc. Omitted platforms leave the existing value
/// intact (useful for OTP replenishment that re-uploads the identity without
/// new metadata).
pub async fn store_identity_key(
    db: impl sqlx::PgExecutor<'_>,
    user_id: Uuid,
    device_id: i32,
    identity_key: &[u8],
    signing_key: Option<&[u8]>,
    platform: Option<&str>,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO identity_keys (user_id, device_id, identity_key, signing_key, platform) \
         VALUES ($1, $2, $3, $4, $5) \
         ON CONFLICT (user_id, device_id) DO UPDATE \
         SET identity_key = $3, \
             signing_key = $4, \
             platform = COALESCE($5, identity_keys.platform)",
    )
    .bind(user_id)
    .bind(device_id)
    .bind(identity_key)
    .bind(signing_key)
    .bind(platform)
    .execute(db)
    .await?;
    Ok(())
}

/// Store a new signed prekey for a device, keeping the previously active key
/// alive for a 14-day grace period so in-flight X3DH messages from peers that
/// fetched the old bundle can still decrypt successfully.
///
/// Steps (all within the caller's transaction):
/// 1. Expire the currently active row by setting `grace_expires_at`.
/// 2. Insert the new row (no `grace_expires_at` → it becomes the active key).
/// 3. Prune rows whose grace period has already elapsed.
pub async fn store_signed_prekey(
    conn: &mut PgConnection,
    user_id: Uuid,
    device_id: i32,
    key_id: i32,
    public_key: &[u8],
    signature: &[u8],
) -> Result<(), sqlx::Error> {
    // 1. Mark the current active row as entering its grace period.
    sqlx::query(
        "UPDATE signed_prekeys \
         SET grace_expires_at = now() + INTERVAL '14 days' \
         WHERE user_id = $1 AND device_id = $2 AND grace_expires_at IS NULL",
    )
    .bind(user_id)
    .bind(device_id)
    .execute(&mut *conn)
    .await?;

    // 2. Insert the new active key (grace_expires_at stays NULL = active).
    sqlx::query(
        "INSERT INTO signed_prekeys (user_id, device_id, key_id, public_key, signature) \
         VALUES ($1, $2, $3, $4, $5) \
         ON CONFLICT (user_id, device_id, key_id) DO UPDATE \
         SET public_key = $4, signature = $5, \
             grace_expires_at = NULL, created_at = now()",
    )
    .bind(user_id)
    .bind(device_id)
    .bind(key_id)
    .bind(public_key)
    .bind(signature)
    .execute(&mut *conn)
    .await?;

    // 3. Purge rows whose grace period has elapsed.
    sqlx::query(
        "DELETE FROM signed_prekeys \
         WHERE user_id = $1 AND device_id = $2 \
           AND grace_expires_at IS NOT NULL AND grace_expires_at < now()",
    )
    .bind(user_id)
    .bind(device_id)
    .execute(&mut *conn)
    .await?;

    Ok(())
}

/// Store one-time prekeys for a user's device.
///
/// Uses DO UPDATE to self-heal if the client re-uploads a key_id that already
/// exists (e.g. counter reset).  The client always holds the private key for
/// the most recently generated OTP, so the server must store the matching
/// public key.  Also resets `used = false` so the key is consumable again.
pub async fn store_one_time_prekeys(
    conn: &mut PgConnection,
    user_id: Uuid,
    device_id: i32,
    prekeys: &[(i32, Vec<u8>)],
) -> Result<(), sqlx::Error> {
    if prekeys.is_empty() {
        return Ok(());
    }

    // Build a single batch INSERT: VALUES ($1,$2,$3,$4), ($1,$2,$5,$6), ...
    let mut query = String::from(
        "INSERT INTO one_time_prekeys (user_id, device_id, key_id, public_key) VALUES ",
    );
    // $1 = user_id, $2 = device_id, then pairs of (key_id, public_key)
    let mut param_idx = 3_u32; // first two params are user_id and device_id
    for (i, _) in prekeys.iter().enumerate() {
        if i > 0 {
            query.push_str(", ");
        }
        query.push_str(&format!("($1, $2, ${}, ${})", param_idx, param_idx + 1));
        param_idx += 2;
    }
    query.push_str(
        " ON CONFLICT (user_id, device_id, key_id) \
         DO UPDATE SET public_key = EXCLUDED.public_key, used = false",
    );

    let mut q = sqlx::query(&query).bind(user_id).bind(device_id);
    for (key_id, public_key) in prekeys {
        q = q.bind(key_id).bind(public_key);
    }
    q.execute(&mut *conn).await?;
    Ok(())
}

/// Fetch a user's PreKey bundle for a specific device, consuming one one-time prekey if available.
pub async fn get_prekey_bundle(
    pool: &PgPool,
    user_id: Uuid,
    device_id: i32,
) -> Result<Option<PreKeyBundleRow>, sqlx::Error> {
    // Fetch identity key for this device
    let identity_row: Option<(Vec<u8>, Option<Vec<u8>>)> = sqlx::query_as(
        "SELECT identity_key, signing_key FROM identity_keys WHERE user_id = $1 AND device_id = $2",
    )
    .bind(user_id)
    .bind(device_id)
    .fetch_optional(pool)
    .await?;

    let (identity_key, signing_key) = match identity_row {
        Some((k, sk)) => (k, sk),
        None => return Ok(None),
    };

    // Fetch the current active signed prekey for this device (grace_expires_at IS NULL).
    // Fall back to the most recently created in-grace-period row if no active key exists.
    let spk_row: Option<(i32, Vec<u8>, Vec<u8>)> = sqlx::query_as(
        "SELECT key_id, public_key, signature FROM signed_prekeys \
         WHERE user_id = $1 AND device_id = $2 \
           AND (grace_expires_at IS NULL OR grace_expires_at > now()) \
         ORDER BY grace_expires_at IS NULL DESC, created_at DESC \
         LIMIT 1",
    )
    .bind(user_id)
    .bind(device_id)
    .fetch_optional(pool)
    .await?;

    let (signed_prekey_id, signed_prekey, signed_prekey_signature) = match spk_row {
        Some(row) => row,
        None => return Ok(None),
    };

    // Consume one one-time prekey for this device (atomically)
    let otp_row: Option<(i32, Vec<u8>)> = sqlx::query_as(
        "UPDATE one_time_prekeys SET used = true \
         WHERE id = ( \
             SELECT id FROM one_time_prekeys \
             WHERE user_id = $1 AND device_id = $2 AND NOT used \
             ORDER BY id ASC LIMIT 1 \
             FOR UPDATE SKIP LOCKED \
         ) RETURNING key_id, public_key",
    )
    .bind(user_id)
    .bind(device_id)
    .fetch_optional(pool)
    .await?;

    let one_time_prekey =
        otp_row.map(|(key_id, public_key)| OneTimePreKeyRow { key_id, public_key });

    Ok(Some(PreKeyBundleRow {
        identity_key,
        signing_key,
        signed_prekey,
        signed_prekey_signature,
        signed_prekey_id,
        one_time_prekey,
    }))
}

/// Device metadata returned by [`get_user_devices`].
#[derive(Debug, serde::Serialize, sqlx::FromRow)]
pub struct DeviceRow {
    pub device_id: i32,
    pub platform: Option<String>,
    pub last_seen: Option<DateTime<Utc>>,
}

/// Return devices registered for a given user (capped at 10), including
/// their platform and last-seen timestamp.
pub async fn get_user_devices(pool: &PgPool, user_id: Uuid) -> Result<Vec<DeviceRow>, sqlx::Error> {
    sqlx::query_as::<_, DeviceRow>(
        "SELECT device_id, platform, last_seen \
         FROM identity_keys \
         WHERE user_id = $1 \
         ORDER BY device_id DESC \
         LIMIT 10",
    )
    .bind(user_id)
    .fetch_all(pool)
    .await
}

/// Update the `last_seen` timestamp for a user's device to NOW(). Called on
/// WebSocket connect so the device list reflects recent activity.
pub async fn update_last_seen(
    pool: &PgPool,
    user_id: Uuid,
    device_id: i32,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE identity_keys SET last_seen = NOW() \
         WHERE user_id = $1 AND device_id = $2",
    )
    .bind(user_id)
    .bind(device_id)
    .execute(pool)
    .await?;
    Ok(())
}

/// Revoke all keys for a specific (user_id, device_id) pair.
/// Returns true if any rows were deleted, false if the device was not found.
pub async fn revoke_device(
    pool: &PgPool,
    user_id: Uuid,
    device_id: i32,
) -> Result<bool, sqlx::Error> {
    let mut tx = pool.begin().await?;

    // Delete identity key binding first (FK constraint from prekeys)
    let r1 = sqlx::query("DELETE FROM identity_keys WHERE user_id = $1 AND device_id = $2")
        .bind(user_id)
        .bind(device_id)
        .execute(&mut *tx)
        .await?;

    sqlx::query("DELETE FROM signed_prekeys WHERE user_id = $1 AND device_id = $2")
        .bind(user_id)
        .bind(device_id)
        .execute(&mut *tx)
        .await?;

    sqlx::query("DELETE FROM one_time_prekeys WHERE user_id = $1 AND device_id = $2")
        .bind(user_id)
        .bind(device_id)
        .execute(&mut *tx)
        .await?;

    tx.commit().await?;
    Ok(r1.rows_affected() > 0)
}

/// Revoke every device belonging to `user_id` except `keep_device_id` in a
/// single transaction. Returns the list of device IDs that were revoked so the
/// caller can fan out WS notifications without another DB round-trip.
pub async fn revoke_devices_except(
    pool: &PgPool,
    user_id: Uuid,
    keep_device_id: i32,
) -> Result<Vec<i32>, sqlx::Error> {
    let mut tx = pool.begin().await?;

    let revoked: Vec<(i32,)> = sqlx::query_as(
        "SELECT device_id FROM identity_keys \
         WHERE user_id = $1 AND device_id != $2",
    )
    .bind(user_id)
    .bind(keep_device_id)
    .fetch_all(&mut *tx)
    .await?;

    sqlx::query("DELETE FROM identity_keys WHERE user_id = $1 AND device_id != $2")
        .bind(user_id)
        .bind(keep_device_id)
        .execute(&mut *tx)
        .await?;

    sqlx::query("DELETE FROM signed_prekeys WHERE user_id = $1 AND device_id != $2")
        .bind(user_id)
        .bind(keep_device_id)
        .execute(&mut *tx)
        .await?;

    sqlx::query("DELETE FROM one_time_prekeys WHERE user_id = $1 AND device_id != $2")
        .bind(user_id)
        .bind(keep_device_id)
        .execute(&mut *tx)
        .await?;

    tx.commit().await?;

    Ok(revoked.into_iter().map(|(id,)| id).collect())
}

/// Count available (unused) one-time prekeys for a user's device.
pub async fn count_one_time_prekeys(
    pool: &PgPool,
    user_id: Uuid,
    device_id: i32,
) -> Result<i64, sqlx::Error> {
    let row: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM one_time_prekeys \
         WHERE user_id = $1 AND device_id = $2 AND NOT used",
    )
    .bind(user_id)
    .bind(device_id)
    .fetch_one(pool)
    .await?;
    Ok(row.0)
}

// -------------------------------------------------------------------------
// Group encryption keys
// -------------------------------------------------------------------------

/// Row returned by group_keys queries.
#[derive(Debug, serde::Serialize, sqlx::FromRow)]
pub struct GroupKeyRow {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub key_version: i32,
    pub encrypted_key: String,
    pub created_by: Uuid,
    pub created_at: DateTime<Utc>,
}

/// Insert a new group key version.
pub async fn store_group_key(
    pool: &PgPool,
    conversation_id: Uuid,
    key_version: i32,
    encrypted_key: &str,
    created_by: Uuid,
) -> Result<GroupKeyRow, sqlx::Error> {
    sqlx::query_as::<_, GroupKeyRow>(
        "INSERT INTO group_keys \
             (conversation_id, key_version, encrypted_key, created_by) \
         VALUES ($1, $2, $3, $4) \
         RETURNING id, conversation_id, key_version, encrypted_key, \
                   created_by, created_at",
    )
    .bind(conversation_id)
    .bind(key_version)
    .bind(encrypted_key)
    .bind(created_by)
    .fetch_one(pool)
    .await
}

/// Get the latest (highest-version) group key for a conversation.
pub async fn get_latest_group_key(
    pool: &PgPool,
    conversation_id: Uuid,
) -> Result<Option<GroupKeyRow>, sqlx::Error> {
    sqlx::query_as::<_, GroupKeyRow>(
        "SELECT id, conversation_id, key_version, encrypted_key, \
                created_by, created_at \
         FROM group_keys \
         WHERE conversation_id = $1 \
         ORDER BY key_version DESC \
         LIMIT 1",
    )
    .bind(conversation_id)
    .fetch_optional(pool)
    .await
}

/// Get a specific group key version for a conversation.
pub async fn get_group_key(
    pool: &PgPool,
    conversation_id: Uuid,
    key_version: i32,
) -> Result<Option<GroupKeyRow>, sqlx::Error> {
    sqlx::query_as::<_, GroupKeyRow>(
        "SELECT id, conversation_id, key_version, encrypted_key, \
                created_by, created_at \
         FROM group_keys \
         WHERE conversation_id = $1 AND key_version = $2",
    )
    .bind(conversation_id)
    .bind(key_version)
    .fetch_optional(pool)
    .await
}

// -------------------------------------------------------------------------
// Per-member encrypted group key envelopes
// -------------------------------------------------------------------------

/// Row returned by group_key_envelopes queries.
#[derive(Debug, serde::Serialize, sqlx::FromRow)]
pub struct GroupKeyEnvelopeRow {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub key_version: i32,
    pub recipient_user_id: Uuid,
    pub encrypted_key: String,
    pub created_at: DateTime<Utc>,
}

/// Store an encrypted group key envelope for a specific recipient.
pub async fn store_group_key_envelope(
    pool: &PgPool,
    conversation_id: Uuid,
    key_version: i32,
    recipient_user_id: Uuid,
    encrypted_key: &str,
) -> Result<GroupKeyEnvelopeRow, sqlx::Error> {
    sqlx::query_as::<_, GroupKeyEnvelopeRow>(
        "INSERT INTO group_key_envelopes \
             (conversation_id, key_version, recipient_user_id, encrypted_key) \
         VALUES ($1, $2, $3, $4) \
         ON CONFLICT (conversation_id, key_version, recipient_user_id) \
         DO UPDATE SET encrypted_key = $4 \
         RETURNING id, conversation_id, key_version, recipient_user_id, \
                   encrypted_key, created_at",
    )
    .bind(conversation_id)
    .bind(key_version)
    .bind(recipient_user_id)
    .bind(encrypted_key)
    .fetch_one(pool)
    .await
}

/// Get the latest group key envelope for a specific user in a conversation.
pub async fn get_my_group_key_envelope(
    pool: &PgPool,
    conversation_id: Uuid,
    user_id: Uuid,
) -> Result<Option<GroupKeyEnvelopeRow>, sqlx::Error> {
    sqlx::query_as::<_, GroupKeyEnvelopeRow>(
        "SELECT id, conversation_id, key_version, recipient_user_id, \
                encrypted_key, created_at \
         FROM group_key_envelopes \
         WHERE conversation_id = $1 AND recipient_user_id = $2 \
         ORDER BY key_version DESC \
         LIMIT 1",
    )
    .bind(conversation_id)
    .bind(user_id)
    .fetch_optional(pool)
    .await
}

/// Get a specific version of a group key envelope for a user.
pub async fn get_my_group_key_envelope_version(
    pool: &PgPool,
    conversation_id: Uuid,
    user_id: Uuid,
    key_version: i32,
) -> Result<Option<GroupKeyEnvelopeRow>, sqlx::Error> {
    sqlx::query_as::<_, GroupKeyEnvelopeRow>(
        "SELECT id, conversation_id, key_version, recipient_user_id, \
                encrypted_key, created_at \
         FROM group_key_envelopes \
         WHERE conversation_id = $1 AND recipient_user_id = $2 \
               AND key_version = $3",
    )
    .bind(conversation_id)
    .bind(user_id)
    .bind(key_version)
    .fetch_optional(pool)
    .await
}
