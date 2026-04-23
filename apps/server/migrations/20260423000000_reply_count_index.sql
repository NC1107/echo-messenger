-- Index for efficient reply_count correlated subqueries.
-- Partial index: only rows that are actual replies (reply_to_id IS NOT NULL).
CREATE INDEX IF NOT EXISTS idx_messages_reply_to_id
    ON messages (reply_to_id)
    WHERE reply_to_id IS NOT NULL;
