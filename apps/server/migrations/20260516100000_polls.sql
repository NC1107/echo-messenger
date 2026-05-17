-- Polls-in-chat MVP.
--
-- Two separate tables keep poll data off the messages hot path and allow
-- one-vote-per-user enforcement at the DB level.
--
-- message_polls: one row per poll message.
--   - question: the poll question text
--   - options: JSONB array of option strings, e.g. ["Yes", "No", "Maybe"]
--
-- poll_votes: one row per (message, user) pair — the PK enforces the
--   one-vote-per-user rule at the DB level. The option_index is validated
--   server-side before insert to stay within the options array bounds.

CREATE TABLE IF NOT EXISTS message_polls (
    message_id UUID PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
    question   TEXT    NOT NULL,
    options    JSONB   NOT NULL
);

CREATE TABLE IF NOT EXISTS poll_votes (
    message_id   UUID    NOT NULL REFERENCES message_polls(message_id) ON DELETE CASCADE,
    user_id      UUID    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    option_index INTEGER NOT NULL,
    voted_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS poll_votes_message_idx ON poll_votes (message_id);
