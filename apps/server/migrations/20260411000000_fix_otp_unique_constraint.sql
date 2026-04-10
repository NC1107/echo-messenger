-- Fix OTP key ID collision: scope uniqueness to (user_id, device_id, key_id)
-- instead of just (user_id, key_id).  The old constraint prevented different
-- devices from uploading OTP keys with the same key_id, and more critically,
-- caused ON CONFLICT DO NOTHING to silently discard new key material when the
-- client re-uploaded with the same IDs after a restart.
ALTER TABLE one_time_prekeys DROP CONSTRAINT IF EXISTS one_time_prekeys_user_id_key_id_key;

-- Use a unique index instead of a constraint so we can use IF NOT EXISTS.
CREATE UNIQUE INDEX IF NOT EXISTS idx_otp_user_device_key
    ON one_time_prekeys(user_id, device_id, key_id);
