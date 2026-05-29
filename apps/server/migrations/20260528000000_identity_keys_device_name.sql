-- Editable per-device display name (1-40 chars, trimmed).
-- Set on first key-upload from the user-agent / platform hint, and may be
-- rewritten by the owner via PATCH /api/keys/device/:device_id.
ALTER TABLE identity_keys
    ADD COLUMN IF NOT EXISTS device_name TEXT;
