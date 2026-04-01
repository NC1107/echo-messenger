-- For unread count queries
CREATE INDEX IF NOT EXISTS idx_messages_conv_sender_created ON messages(conversation_id, sender_id, created_at);

-- For last message in conversation (sidebar)
CREATE INDEX IF NOT EXISTS idx_messages_conv_created_desc ON messages(conversation_id, created_at DESC);

-- For reactions per message
CREATE INDEX IF NOT EXISTS idx_reactions_msg_user ON reactions(message_id, user_id);

-- For sender lookups
CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_id);
