-- Full-text search index for messages
CREATE INDEX IF NOT EXISTS idx_messages_content_search
  ON messages USING GIN (to_tsvector('english', content))
  WHERE deleted_at IS NULL;

-- Per-user mute flag on conversation membership
ALTER TABLE conversation_members
  ADD COLUMN IF NOT EXISTS is_muted BOOLEAN NOT NULL DEFAULT false;
