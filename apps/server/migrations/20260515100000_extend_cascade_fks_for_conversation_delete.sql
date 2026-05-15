-- #785: extend ON DELETE CASCADE to every remaining FK that references
-- conversations(id), so a single `DELETE FROM conversations WHERE id = $1`
-- cleans up all dependent rows atomically and `delete_group_dependents`
-- can collapse to a single call to `force_delete_conversation`.
--
-- Audit performed via `grep -rn 'REFERENCES conversations' apps/server/migrations/`
-- and a follow-up scan over every child / grandchild table. Results:
--
--   conversation_members.conversation_id   -- CASCADE (20260412000000)
--   messages.conversation_id               -- CASCADE (20260412000000)
--   read_receipts.conversation_id          -- CASCADE (20260412000000)
--   channels.conversation_id               -- CASCADE (baseline)
--   banned_members.conversation_id         -- CASCADE (baseline)
--   group_keys.conversation_id             -- CASCADE (20260406000000)
--   group_key_envelopes.conversation_id    -- CASCADE (20260406100000)
--   pinned_conversations.conversation_id   -- CASCADE (20260426000001)
--   direct_conversations.conversation_id   -- CASCADE (20260430000001)
--   group_invite_tokens.conversation_id    -- CASCADE (20260501200000)
--   media.conversation_id                  -- NO CASCADE (baseline 17.) <-- fixed here
--
-- Grandchildren (transitively cascade via their parent's CASCADE):
--   channels(id)        -> voice_sessions, channel_canvas               (CASCADE)
--   messages(id)        -> reactions, message_device_contents,
--                          message_deliveries, mentions                 (CASCADE)
--   messages.channel_id -> ON DELETE SET NULL (irrelevant: messages
--                          themselves cascade via conversation_id)
--   messages.reply_to_id -> ON DELETE SET NULL (self-ref, fine)
--
-- After this migration, the only conversation-FK without CASCADE is gone,
-- so deleting a conversation cascades to every dependent row at the DB
-- level. The application-layer `delete_group_dependents` loop becomes
-- redundant and is collapsed in the matching code change.

ALTER TABLE media DROP CONSTRAINT IF EXISTS media_conversation_id_fkey;
ALTER TABLE media ADD CONSTRAINT media_conversation_id_fkey
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE;
