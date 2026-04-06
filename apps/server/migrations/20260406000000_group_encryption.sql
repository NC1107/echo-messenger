-- Group encryption: store encrypted symmetric keys per conversation version.
-- Server stores the base64-encoded ciphertext but cannot decrypt it.

CREATE TABLE IF NOT EXISTS group_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    key_version INT NOT NULL DEFAULT 1,
    encrypted_key TEXT NOT NULL,
    created_by UUID NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(conversation_id, key_version)
);

CREATE INDEX IF NOT EXISTS idx_group_keys_conversation
    ON group_keys(conversation_id, key_version DESC);
