-- Server-side mention persistence (#451 follow-up).
--
-- Each row records that `mentioned_user_id` was mentioned in `message_id`.
-- The `list_conversations` query joins this against `read_receipts` to
-- compute an unread mention count per (user, conversation) so the badge
-- survives a refresh.  Client-side mention detection on incoming WS
-- messages still drives the optimistic in-flight bump; this table is the
-- source of truth on reload.
--
-- Encrypted groups skip server-side detection -- the server never sees
-- plaintext, so mentions of `@<user>` / `@everyone` / `@here` cannot be
-- extracted there.  For those conversations the client-side count remains
-- best-effort and resets on refresh until per-recipient device crypto
-- carries mention metadata in the envelope (separate slice).

CREATE TABLE IF NOT EXISTS mentions (
    message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    mentioned_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (message_id, mentioned_user_id)
);

-- Reverse-lookup index for the `list_conversations` query: counts
-- mentions per recipient per message-set scoped by conversation, so the
-- access pattern is (user_id, message_id) -> exists.
CREATE INDEX IF NOT EXISTS idx_mentions_user
    ON mentions (mentioned_user_id, message_id);
