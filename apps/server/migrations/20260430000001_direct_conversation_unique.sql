-- Canonical lookup table that enforces one DM conversation per user pair.
--
-- user_lo / user_hi hold the two participants in sorted (lo < hi) order so
-- the PRIMARY KEY (user_lo, user_hi) is a schema-level uniqueness guard.
-- The application always writes LEAST(a,b) into user_lo and GREATEST(a,b)
-- into user_hi, making the constraint order-independent.

CREATE TABLE IF NOT EXISTS direct_conversations (
    user_lo         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user_hi         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    conversation_id UUID NOT NULL UNIQUE REFERENCES conversations(id) ON DELETE CASCADE,
    PRIMARY KEY (user_lo, user_hi),
    CONSTRAINT direct_conversations_canonical CHECK (user_lo < user_hi)
);

-- Backfill from existing DM conversations.  For each direct conversation with
-- exactly two active members, register the canonical (lo, hi) pair.  When the
-- race condition has already produced duplicates, we keep the oldest one
-- (lowest created_at) per pair and skip the rest via ON CONFLICT DO NOTHING.

WITH ranked_dms AS (
    SELECT
        LEAST(cm1.user_id, cm2.user_id)    AS user_lo,
        GREATEST(cm1.user_id, cm2.user_id) AS user_hi,
        c.id                               AS conversation_id,
        ROW_NUMBER() OVER (
            PARTITION BY LEAST(cm1.user_id, cm2.user_id),
                         GREATEST(cm1.user_id, cm2.user_id)
            ORDER BY c.created_at
        ) AS rn
    FROM conversations c
    JOIN conversation_members cm1
        ON cm1.conversation_id = c.id AND cm1.is_removed = false
    JOIN conversation_members cm2
        ON cm2.conversation_id = c.id AND cm2.is_removed = false
    WHERE c.kind = 'direct'
      AND cm1.user_id < cm2.user_id
      AND NOT EXISTS (
          SELECT 1 FROM conversation_members cm3
          WHERE cm3.conversation_id = c.id
            AND cm3.user_id != cm1.user_id
            AND cm3.user_id != cm2.user_id
            AND cm3.is_removed = false
      )
)
INSERT INTO direct_conversations (user_lo, user_hi, conversation_id)
SELECT user_lo, user_hi, conversation_id
FROM   ranked_dms
WHERE  rn = 1
ON CONFLICT (user_lo, user_hi) DO NOTHING;
