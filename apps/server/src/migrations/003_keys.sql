CREATE TABLE IF NOT EXISTS identity_keys (
    user_id UUID PRIMARY KEY REFERENCES users(id),
    identity_key BYTEA NOT NULL
);

CREATE TABLE IF NOT EXISTS signed_prekeys (
    user_id UUID PRIMARY KEY REFERENCES users(id),
    key_id INTEGER NOT NULL,
    public_key BYTEA NOT NULL,
    signature BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS one_time_prekeys (
    id SERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id),
    key_id INTEGER NOT NULL,
    public_key BYTEA NOT NULL,
    used BOOLEAN NOT NULL DEFAULT false,
    UNIQUE(user_id, key_id)
);
CREATE INDEX IF NOT EXISTS idx_otp_available ON one_time_prekeys(user_id, used) WHERE NOT used;
