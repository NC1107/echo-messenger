-- Add family_id to refresh_tokens for token theft detection.
--
-- All tokens issued from the same login session share a family_id.
-- When a revoked token is presented during refresh, ALL tokens in
-- that family are revoked (the entire session is compromised).
ALTER TABLE refresh_tokens ADD COLUMN family_id UUID DEFAULT gen_random_uuid();
CREATE INDEX idx_refresh_tokens_family ON refresh_tokens(family_id);
