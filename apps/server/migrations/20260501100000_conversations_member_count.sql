-- Denormalized member_count column on conversations (#640)
--
-- Replaces the live COUNT(cm.user_id) GROUP BY in list_public_groups with a
-- maintained integer so the query drops the aggregation and sorts by a plain
-- column.  A partial index on (member_count DESC) for public groups makes the
-- directory listing O(log n) instead of O(n) in member rows.

ALTER TABLE conversations
    ADD COLUMN IF NOT EXISTS member_count INTEGER NOT NULL DEFAULT 0;

-- Backfill from current active membership rows.
UPDATE conversations
SET member_count = (
    SELECT COUNT(*)
    FROM conversation_members
    WHERE conversation_id = conversations.id
      AND is_removed = false
);

-- Partial index for the public-group directory sort path.
CREATE INDEX IF NOT EXISTS idx_conversations_public_member_count
    ON conversations (member_count DESC)
    WHERE is_public = true;
