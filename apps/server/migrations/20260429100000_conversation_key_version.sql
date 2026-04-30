-- #656 Group key rotation on member kick/leave.
--
-- Track the latest group-key version directly on the conversation row so the
-- server can atomically bump it when a member is removed and so clients can
-- short-circuit unnecessary key fetches when the local cache matches.
ALTER TABLE conversations
    ADD COLUMN IF NOT EXISTS key_version INT NOT NULL DEFAULT 1;
