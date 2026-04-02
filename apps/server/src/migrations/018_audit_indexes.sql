CREATE INDEX IF NOT EXISTS idx_messages_deleted ON messages(deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_read_receipts_conv_user ON read_receipts(conversation_id, user_id);
CREATE INDEX IF NOT EXISTS idx_messages_channel ON messages(channel_id, created_at DESC) WHERE channel_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_messages_conv_unread ON messages(conversation_id, sender_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_voice_sessions_user ON voice_sessions(user_id);
