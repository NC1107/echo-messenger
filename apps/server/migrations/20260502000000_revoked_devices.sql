-- Soft-delete for device revocation (#657).
--
-- Previously, revoking a device hard-deleted its identity_keys row.  This made
-- it impossible to distinguish "never registered" (fixtures, fresh devices) from
-- "was registered, now revoked" — causing the fanout filter to drop ciphertexts
-- for unknown devices, breaking every test fixture.
--
-- Adding revoked_at lets revoke_device do an UPDATE instead of DELETE, and the
-- fanout filter can then precisely drop only revoked entries while passing through
-- unknown ones.
ALTER TABLE identity_keys
    ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ;

-- Speed up the revocation-check query used during message fanout.
CREATE INDEX IF NOT EXISTS idx_identity_keys_revoked
    ON identity_keys (user_id, device_id)
    WHERE revoked_at IS NOT NULL;
