//! PreKey bundle database queries.

use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, serde::Serialize)]
pub struct PreKeyBundleRow {
    pub identity_key: Vec<u8>,
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

/// Store or replace a user's identity key.
pub async fn store_identity_key(
    pool: &PgPool,
    user_id: Uuid,
    identity_key: &[u8],
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO identity_keys (user_id, identity_key) VALUES ($1, $2) \
         ON CONFLICT (user_id) DO UPDATE SET identity_key = $2",
    )
    .bind(user_id)
    .bind(identity_key)
    .execute(pool)
    .await?;
    Ok(())
}

/// Store or replace a user's signed prekey.
pub async fn store_signed_prekey(
    pool: &PgPool,
    user_id: Uuid,
    key_id: i32,
    public_key: &[u8],
    signature: &[u8],
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO signed_prekeys (user_id, key_id, public_key, signature) \
         VALUES ($1, $2, $3, $4) \
         ON CONFLICT (user_id) DO UPDATE SET key_id = $2, public_key = $3, signature = $4, created_at = now()",
    )
    .bind(user_id)
    .bind(key_id)
    .bind(public_key)
    .bind(signature)
    .execute(pool)
    .await?;
    Ok(())
}

/// Store one-time prekeys for a user (appends, does not replace).
pub async fn store_one_time_prekeys(
    pool: &PgPool,
    user_id: Uuid,
    prekeys: &[(i32, Vec<u8>)],
) -> Result<(), sqlx::Error> {
    for (key_id, public_key) in prekeys {
        sqlx::query(
            "INSERT INTO one_time_prekeys (user_id, key_id, public_key) \
             VALUES ($1, $2, $3) \
             ON CONFLICT (user_id, key_id) DO NOTHING",
        )
        .bind(user_id)
        .bind(key_id)
        .bind(public_key)
        .execute(pool)
        .await?;
    }
    Ok(())
}

/// Fetch a user's PreKey bundle, consuming one one-time prekey if available.
pub async fn get_prekey_bundle(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Option<PreKeyBundleRow>, sqlx::Error> {
    // Fetch identity key
    let identity_row: Option<(Vec<u8>,)> =
        sqlx::query_as("SELECT identity_key FROM identity_keys WHERE user_id = $1")
            .bind(user_id)
            .fetch_optional(pool)
            .await?;

    let identity_key = match identity_row {
        Some((k,)) => k,
        None => return Ok(None),
    };

    // Fetch signed prekey
    let spk_row: Option<(i32, Vec<u8>, Vec<u8>)> = sqlx::query_as(
        "SELECT key_id, public_key, signature FROM signed_prekeys WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await?;

    let (signed_prekey_id, signed_prekey, signed_prekey_signature) = match spk_row {
        Some(row) => row,
        None => return Ok(None),
    };

    // Consume one one-time prekey (atomically mark as used and return it)
    let otp_row: Option<(i32, Vec<u8>)> = sqlx::query_as(
        "UPDATE one_time_prekeys SET used = true \
         WHERE id = ( \
             SELECT id FROM one_time_prekeys \
             WHERE user_id = $1 AND NOT used \
             ORDER BY id ASC LIMIT 1 \
             FOR UPDATE SKIP LOCKED \
         ) RETURNING key_id, public_key",
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await?;

    let one_time_prekey =
        otp_row.map(|(key_id, public_key)| OneTimePreKeyRow { key_id, public_key });

    Ok(Some(PreKeyBundleRow {
        identity_key,
        signed_prekey,
        signed_prekey_signature,
        signed_prekey_id,
        one_time_prekey,
    }))
}

/// Count available (unused) one-time prekeys for a user.
#[allow(dead_code)] // Will be used for prekey replenishment logic
pub async fn count_one_time_prekeys(pool: &PgPool, user_id: Uuid) -> Result<i64, sqlx::Error> {
    let row: (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM one_time_prekeys WHERE user_id = $1 AND NOT used")
            .bind(user_id)
            .fetch_one(pool)
            .await?;
    Ok(row.0)
}
