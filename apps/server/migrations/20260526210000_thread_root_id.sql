-- Threads M2 (docs/threads-architecture.md §3).
--
-- thread_root_id points at the ROOT of a thread (immutable for the life of
-- the thread). Distinct from reply_to_id, which still names the immediate
-- quoted parent. When set, the row is a thread reply and is filtered OUT
-- of the main channel timeline by get_messages — it only renders in the
-- thread panel.
--
-- Existing replies keep thread_root_id NULL, so they stay in the main
-- timeline (back-compat: the semantic shift is too large to apply
-- retroactively; only new replies flagged "Reply in thread" go thread-
-- only).
ALTER TABLE messages
  ADD COLUMN thread_root_id UUID NULL
  REFERENCES messages(id) ON DELETE SET NULL;

-- Hot path: load thread N replies for a parent. Partial index because the
-- column is sparse (most messages aren't thread replies).
CREATE INDEX idx_messages_thread_root
  ON messages (conversation_id, thread_root_id)
  WHERE thread_root_id IS NOT NULL AND deleted_at IS NULL;
