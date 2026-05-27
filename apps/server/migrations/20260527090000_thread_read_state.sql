-- Threads M3 (docs/threads-architecture.md §4: per-thread unread state).
--
-- One row per (user, thread_root_id) recording when the user last viewed
-- that thread. The threads-inbox + per-thread badges compare
-- last_read_at to the thread's most-recent reply (m.created_at) to
-- compute the unread count.
--
-- Schema is intentionally narrow: no follower/subscriber concept yet —
-- visibility comes from membership in the parent's conversation. A
-- thread is "visible" if the user is in the conversation; it shows in
-- the inbox if it has at least one reply AND the user has visibility.
CREATE TABLE thread_read_state (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    thread_root_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    last_read_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, thread_root_id)
);

-- Hot path: the inbox query walks every thread root the user can see
-- (in conversations they're a member of) and joins thread_read_state to
-- compute unread counts. Index by (user_id) for that join + (thread_
-- root_id) for the mark-read upsert.
CREATE INDEX idx_thread_read_state_user
  ON thread_read_state (user_id);
