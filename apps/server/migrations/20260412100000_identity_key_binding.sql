-- Add a canonical identity key fingerprint to the users table.
-- On first key bundle upload, the server stores SHA-256(identity_key) here.
-- Subsequent uploads must present the same identity key or the server
-- rejects the request with 409 Conflict. Identity key rotation requires
-- a separate key-reset flow (not yet implemented).
ALTER TABLE users ADD COLUMN IF NOT EXISTS identity_key_fingerprint BYTEA;
