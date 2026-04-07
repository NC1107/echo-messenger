-- Per-member encrypted group key distribution.
-- Instead of storing a single plaintext key per version, each member gets
-- the group key encrypted specifically for them using their identity public key.
-- The server never sees the raw AES group key.

CREATE TABLE IF NOT EXISTS group_key_envelopes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    key_version INT NOT NULL,
    recipient_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    encrypted_key TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(conversation_id, key_version, recipient_user_id)
);

CREATE INDEX IF NOT EXISTS idx_group_key_envelopes_recipient
    ON group_key_envelopes(conversation_id, recipient_user_id, key_version DESC);
