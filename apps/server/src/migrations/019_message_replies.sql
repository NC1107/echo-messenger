ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS reply_to_id UUID REFERENCES messages(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_messages_reply_to
    ON messages (reply_to_id)
    WHERE reply_to_id IS NOT NULL;
