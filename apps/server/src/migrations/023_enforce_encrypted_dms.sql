-- Enforce encrypted-only direct messages.
-- Backfill legacy direct conversations that were created before DM encryption
-- was required.
UPDATE conversations
SET is_encrypted = true
WHERE kind = 'direct' AND NOT is_encrypted;

-- Keep privacy preferences aligned with encrypted-only DM policy.
ALTER TABLE users
ALTER COLUMN allow_unencrypted_dm SET DEFAULT false;

UPDATE users
SET allow_unencrypted_dm = false
WHERE allow_unencrypted_dm;
