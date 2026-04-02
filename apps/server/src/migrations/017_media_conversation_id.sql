ALTER TABLE media ADD COLUMN IF NOT EXISTS conversation_id UUID REFERENCES conversations(id);
CREATE INDEX IF NOT EXISTS idx_media_conversation ON media(conversation_id);
