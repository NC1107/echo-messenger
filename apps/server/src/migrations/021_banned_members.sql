-- Ban system: track banned members per group
CREATE TABLE IF NOT EXISTS banned_members (
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    banned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    banned_by UUID NOT NULL REFERENCES users(id),
    PRIMARY KEY (conversation_id, user_id)
);
