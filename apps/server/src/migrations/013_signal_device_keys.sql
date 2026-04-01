-- Add device_id to identity_keys (default 0 for existing single-device clients)
ALTER TABLE identity_keys ADD COLUMN IF NOT EXISTS device_id INT NOT NULL DEFAULT 0;
ALTER TABLE identity_keys ADD COLUMN IF NOT EXISTS signing_key BYTEA;
ALTER TABLE identity_keys DROP CONSTRAINT IF EXISTS identity_keys_pkey;
ALTER TABLE identity_keys ADD PRIMARY KEY (user_id, device_id);

-- Add device_id to signed_prekeys
ALTER TABLE signed_prekeys ADD COLUMN IF NOT EXISTS device_id INT NOT NULL DEFAULT 0;
ALTER TABLE signed_prekeys DROP CONSTRAINT IF EXISTS signed_prekeys_pkey;
ALTER TABLE signed_prekeys ADD PRIMARY KEY (user_id, device_id);

-- Add device_id to one_time_prekeys
ALTER TABLE one_time_prekeys ADD COLUMN IF NOT EXISTS device_id INT NOT NULL DEFAULT 0;
