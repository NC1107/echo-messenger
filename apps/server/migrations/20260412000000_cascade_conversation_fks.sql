-- Add ON DELETE CASCADE to conversation FKs that were missing it.
-- This lets DELETE FROM conversations properly cascade to child rows
-- instead of failing with FK violations or requiring manual cleanup.

-- conversation_members
ALTER TABLE conversation_members DROP CONSTRAINT IF EXISTS conversation_members_conversation_id_fkey;
ALTER TABLE conversation_members ADD CONSTRAINT conversation_members_conversation_id_fkey
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE;

-- messages
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_conversation_id_fkey;
ALTER TABLE messages ADD CONSTRAINT messages_conversation_id_fkey
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE;

-- read_receipts
ALTER TABLE read_receipts DROP CONSTRAINT IF EXISTS read_receipts_conversation_id_fkey;
ALTER TABLE read_receipts ADD CONSTRAINT read_receipts_conversation_id_fkey
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE;
