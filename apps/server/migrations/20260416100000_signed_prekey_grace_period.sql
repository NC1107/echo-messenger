-- Allow multiple signed prekey rows per (user_id, device_id) so that old keys
-- survive during the grace period after rotation.
--
-- The previous PRIMARY KEY (user_id, device_id) enforced one row per device and
-- required ON CONFLICT DO UPDATE (overwrite). The new PK (user_id, device_id,
-- key_id) allows coexistence of the current key and one previous key.
--
-- grace_expires_at: NULL means the row is the current active key.
-- When a new key is uploaded the server sets grace_expires_at = now() + 14 days
-- on the previously active row. Expired rows are pruned on the next upload.

-- 1. Add the grace_expires_at column
ALTER TABLE signed_prekeys ADD COLUMN IF NOT EXISTS grace_expires_at TIMESTAMPTZ;

-- 2. Swap primary key to (user_id, device_id, key_id)
ALTER TABLE signed_prekeys DROP CONSTRAINT IF EXISTS signed_prekeys_pkey;
ALTER TABLE signed_prekeys ADD PRIMARY KEY (user_id, device_id, key_id);

-- 3. Index to speed up "fetch latest active key" queries
CREATE INDEX IF NOT EXISTS idx_signed_prekeys_active
    ON signed_prekeys (user_id, device_id)
    WHERE grace_expires_at IS NULL;
