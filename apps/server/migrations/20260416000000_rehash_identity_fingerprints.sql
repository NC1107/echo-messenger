-- Clear all identity key fingerprints so they rebind on next key upload.
-- Required because the fingerprint now includes both identity_key + signing_key
-- (previously it only covered identity_key, allowing silent signing key rotation).
UPDATE users SET identity_key_fingerprint = NULL WHERE identity_key_fingerprint IS NOT NULL;
