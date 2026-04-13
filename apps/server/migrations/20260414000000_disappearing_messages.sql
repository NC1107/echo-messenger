-- Add disappearing message support.
-- messages.expires_at: when NULL the message never expires; when set, the
--   background cleanup task deletes the row after this timestamp passes.
-- conversations.disappearing_ttl_seconds: if set, new messages in this
--   conversation inherit this TTL (server sets expires_at on store).

ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;

-- Partial index: only index rows that actually have an expiry (avoids bloat).
CREATE INDEX IF NOT EXISTS idx_messages_expires_at
    ON messages (expires_at)
    WHERE expires_at IS NOT NULL;

ALTER TABLE conversations
    ADD COLUMN IF NOT EXISTS disappearing_ttl_seconds INT;
