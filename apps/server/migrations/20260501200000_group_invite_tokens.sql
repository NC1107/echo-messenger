-- Group invite tokens: shareable join links for communities (#579).
--
-- token: 16-byte random, base64url-encoded (22 chars without padding).
-- use_count / max_uses: NULL max_uses means unlimited.
-- expires_at: NULL means never expires.
-- MVP: basic shape shipped. Expiry + max-uses enforcement is functional;
--      UI controls for those fields are deferred to follow-up issues.

CREATE TABLE group_invite_tokens (
    token           VARCHAR(32)  PRIMARY KEY,
    conversation_id UUID         NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    created_by      UUID         NOT NULL REFERENCES users(id)         ON DELETE CASCADE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ  NULL,
    max_uses        INT          NULL,
    use_count       INT          NOT NULL DEFAULT 0
);

CREATE INDEX group_invite_tokens_conversation_idx
    ON group_invite_tokens(conversation_id);
