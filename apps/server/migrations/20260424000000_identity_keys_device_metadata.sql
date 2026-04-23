ALTER TABLE identity_keys
    ADD COLUMN IF NOT EXISTS platform TEXT,
    ADD COLUMN IF NOT EXISTS last_seen TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_identity_keys_last_seen
    ON identity_keys (user_id, last_seen DESC);
