-- Move the canonical identity-key fingerprint from per-USER (`users.identity_key_fingerprint`)
-- to per-(user, device) so multi-device clients can each bind their own
-- identity keys without colliding on the user-level row (#664).
--
-- Strategy: additive. Backfill device 0 from the legacy column so existing
-- single-device users keep their binding. The legacy column is intentionally
-- left in place for one release as a fallback / rollback safety net; it will
-- be dropped in a follow-up migration.
ALTER TABLE identity_keys
    ADD COLUMN IF NOT EXISTS fingerprint BYTEA,
    ADD COLUMN IF NOT EXISTS fingerprint_bound_at TIMESTAMPTZ;

-- Backfill device 0 rows from the legacy per-user fingerprint.
UPDATE identity_keys ik
   SET fingerprint = u.identity_key_fingerprint,
       fingerprint_bound_at = NOW()
  FROM users u
 WHERE ik.user_id = u.id
   AND ik.device_id = 0
   AND ik.fingerprint IS NULL
   AND u.identity_key_fingerprint IS NOT NULL;

-- Partial index keeps lookup cheap for the common (bound) case while ignoring
-- rows whose fingerprint hasn't been written yet.
CREATE INDEX IF NOT EXISTS idx_identity_keys_fingerprint
    ON identity_keys (user_id, device_id)
    WHERE fingerprint IS NOT NULL;

-- DEPRECATED: users.identity_key_fingerprint -- kept for one release as a
-- fallback read path during the per-device fingerprint rollout. Drop in a
-- follow-up migration once all clients have bound their device-level rows.
