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

/// Store or replace a user's identity key for a specific device.
pub async fn store_identity_key(
    db: impl sqlx::PgExecutor<'_>,
    user_id: Uuid,
    device_id: i32,
    identity_key: &[u8],
    signing_key: Option<&[u8]>,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO identity_keys (user_id, device_id, identity_key, signing_key) \
         VALUES ($1, $2, $3, $4) \
         ON CONFLICT (user_id, device_id) DO UPDATE \
         SET identity_key = $3, signing_key = $4",
    )
    .bind(user_id)
    .bind(device_id)
    .bind(identity_key)
    .bind(signing_key)
    .execute(db)
    .await?;
    Ok(())
}

/// Store or replace a user's signed prekey for a specific device.
pub async fn store_signed_prekey(
    db: impl sqlx::PgExecutor<'_>,
    user_id: Uuid,
    device_id: i32,
    key_id: i32,
    public_key: &[u8],
    signature: &[u8],
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO signed_prekeys (user_id, device_id, key_id, public_key, signature) \
         VALUES ($1, $2, $3, $4, $5) \
         ON CONFLICT (user_id, device_id) DO UPDATE \
         SET key_id = $3, public_key = $4, signature = $5, created_at = now()",
    )
    .bind(user_id)
    .bind(device_id)
    .bind(key_id)
    .bind(public_key)
    .bind(signature)
    .execute(db)
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
    for (key_id, public_key) in prekeys {
        sqlx::query(
            "INSERT INTO one_time_prekeys (user_id, device_id, key_id, public_key) \
             VALUES ($1, $2, $3, $4) \
             ON CONFLICT (user_id, device_id, key_id) \
             DO UPDATE SET public_key = EXCLUDED.public_key, \
                           used = false",
        )
        .bind(user_id)
        .bind(device_id)
        .bind(key_id)
        .bind(public_key)
        .execute(&mut *conn)
        .await?;
    }
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

    // Fetch signed prekey for this device
    let spk_row: Option<(i32, Vec<u8>, Vec<u8>)> = sqlx::query_as(
        "SELECT key_id, public_key, signature FROM signed_prekeys \
         WHERE user_id = $1 AND device_id = $2",
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

/// Return all device_ids registered for a given user.
pub async fn get_user_devices(pool: &PgPool, user_id: Uuid) -> Result<Vec<i32>, sqlx::Error> {
    let rows: Vec<(i32,)> = sqlx::query_as(
        "SELECT device_id FROM identity_keys WHERE user_id = $1 ORDER BY device_id DESC",
    )
    .bind(user_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(|(d,)| d).collect())
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
