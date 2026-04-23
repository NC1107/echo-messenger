-- Partial index for efficient undelivered message lookup on WS connect.
CREATE INDEX IF NOT EXISTS idx_messages_undelivered
    ON messages (conversation_id, created_at)
    WHERE delivered = false AND deleted_at IS NULL;
