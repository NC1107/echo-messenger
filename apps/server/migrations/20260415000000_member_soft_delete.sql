-- Add soft-delete columns to conversation_members.
-- Removed members keep their row (for audit trail) but are excluded from
-- active membership checks via the is_removed flag.
ALTER TABLE conversation_members
    ADD COLUMN IF NOT EXISTS is_removed BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS removed_at TIMESTAMPTZ;

-- Index for fast membership lookups that filter out removed members.
CREATE INDEX IF NOT EXISTS idx_conv_members_active
    ON conversation_members (conversation_id, user_id)
    WHERE is_removed = false;
