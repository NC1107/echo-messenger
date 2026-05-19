-- Audit OQ-13: server-side audit log of group key rotations.
--
-- Append-only ledger of every successful group key rotation. Visible
-- to group admins in settings under "Encryption activity". Lets us
-- detect malicious-admin downgrade attempts (e.g. an admin reverting
-- a group from is_encrypted=true to false), abnormal rotation
-- frequency, and gives forensic data when a "Could not decrypt" wave
-- needs to be traced back to a key event.
--
-- Schema (from docs/group-e2e-design/06-open-questions.md §OQ-13):
--   id                       PK
--   conversation_id          which group
--   triggered_by_user_id     who initiated the rotation (i.e. uploaded
--                            the new envelopes -- the server doesn't
--                            see the "start" of a rotation, only the
--                            commit)
--   triggered_by_event       free-form tag: "membership_change",
--                            "explicit_rotate", "first_key", "kick",
--                            "leave", ... the rotator's reason. Stored
--                            as text so future event types don't need a
--                            migration.
--   key_version              the version of the new key
--   completed_at             timestamp of the rotation commit
--   completed_by_user_id     same as triggered_by_user_id for now
--                            (server-led leader election is a follow-
--                            up); kept as a separate column so the
--                            future "leader != trigger source" case
--                            doesn't need a schema change.
--
-- Append-only, no GC. Envelope-row growth is O(versions × members);
-- this table is O(versions), much smaller, no retention concern.

CREATE TABLE IF NOT EXISTS group_key_rotations (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id      UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    triggered_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    triggered_by_event   TEXT NOT NULL,
    key_version          INTEGER NOT NULL CHECK (key_version > 0),
    completed_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- Each (conversation, version) commits exactly once. The upload
    -- endpoint already enforces uniqueness on the key row; mirroring
    -- it here makes a duplicate insert here a hard error instead of a
    -- silent second row.
    UNIQUE (conversation_id, key_version)
);

-- Admin-visible "Encryption activity" lists rotations newest-first
-- per group, so a (conversation_id, completed_at DESC) index covers it.
CREATE INDEX IF NOT EXISTS idx_group_key_rotations_conv_completed
    ON group_key_rotations (conversation_id, completed_at DESC);
