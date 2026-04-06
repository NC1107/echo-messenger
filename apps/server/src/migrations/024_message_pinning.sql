-- Message pinning support
ALTER TABLE messages ADD COLUMN IF NOT EXISTS pinned_by_id UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS pinned_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_messages_pinned ON messages (conversation_id, pinned_at) WHERE pinned_at IS NOT NULL;
