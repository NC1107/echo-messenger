-- Profile background colour: hex string in #RRGGBB form (e.g. #4F46E5).
-- Stored as TEXT for forward-compat with future "preset name" values; client
-- validates against a known palette before persisting.
ALTER TABLE users ADD COLUMN IF NOT EXISTS background_color TEXT;
