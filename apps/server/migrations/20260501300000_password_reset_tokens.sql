-- Password reset tokens: single-use, short-lived tokens for admin-mediated
-- password recovery (#476).
--
-- No email infrastructure exists yet; tokens are logged to stdout via
-- tracing::info for the admin to relay to the user out-of-band.
-- A follow-up issue should add SMTP support for production deployments.
--
-- token: 32-byte random, hex-encoded (64 chars). Single-use.
-- expires_at: 15 minutes from creation.
-- used_at: NULL until consumed; set on first use to make the token invalid.

CREATE TABLE password_reset_tokens (
    token      VARCHAR(64)  PRIMARY KEY,
    user_id    UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ  NOT NULL,
    used_at    TIMESTAMPTZ  NULL
);

CREATE INDEX password_reset_tokens_user_idx
    ON password_reset_tokens(user_id);
