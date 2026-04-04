-- ============================================================================
-- Baseline migration: consolidated from 22 incremental migration files
-- Generated: 2026-04-04
-- Fully idempotent -- safe to run multiple times
-- ============================================================================

-- --------------------------------------------------------------------------
-- 001_initial.sql -- Users table
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    display_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);

-- --------------------------------------------------------------------------
-- 002_messaging.sql -- Contacts, conversations, conversation_members, messages
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS contacts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    requester_id UUID NOT NULL REFERENCES users(id),
    target_id UUID NOT NULL REFERENCES users(id),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'blocked')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(requester_id, target_id)
);
CREATE INDEX IF NOT EXISTS idx_contacts_target ON contacts(target_id, status);
CREATE INDEX IF NOT EXISTS idx_contacts_requester ON contacts(requester_id, status);

CREATE TABLE IF NOT EXISTS conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS conversation_members (
    conversation_id UUID NOT NULL REFERENCES conversations(id),
    user_id UUID NOT NULL REFERENCES users(id),
    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (conversation_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_conv_members_user ON conversation_members(user_id);

CREATE TABLE IF NOT EXISTS messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id),
    sender_id UUID NOT NULL REFERENCES users(id),
    content TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    delivered BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, created_at);

-- --------------------------------------------------------------------------
-- 003_keys.sql -- Signal Protocol key tables
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS identity_keys (
    user_id UUID REFERENCES users(id),
    identity_key BYTEA NOT NULL
);

CREATE TABLE IF NOT EXISTS signed_prekeys (
    user_id UUID REFERENCES users(id),
    key_id INTEGER NOT NULL,
    public_key BYTEA NOT NULL,
    signature BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS one_time_prekeys (
    id SERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id),
    key_id INTEGER NOT NULL,
    public_key BYTEA NOT NULL,
    used BOOLEAN NOT NULL DEFAULT false,
    UNIQUE(user_id, key_id)
);
CREATE INDEX IF NOT EXISTS idx_otp_available ON one_time_prekeys(user_id, used) WHERE NOT used;

-- --------------------------------------------------------------------------
-- 004_reactions.sql -- Conversation kind/title, reactions, read receipts
-- --------------------------------------------------------------------------

ALTER TABLE conversations ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'direct';
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS title TEXT;

CREATE TABLE IF NOT EXISTS reactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id),
    emoji TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(message_id, user_id, emoji)
);
CREATE INDEX IF NOT EXISTS idx_reactions_message ON reactions(message_id);

CREATE TABLE IF NOT EXISTS read_receipts (
    conversation_id UUID NOT NULL REFERENCES conversations(id),
    user_id UUID NOT NULL REFERENCES users(id),
    last_read_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (conversation_id, user_id)
);

-- --------------------------------------------------------------------------
-- 005_media.sql -- Media uploads
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS media (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    uploader_id UUID NOT NULL REFERENCES users(id),
    filename TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    size_bytes BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- --------------------------------------------------------------------------
-- 006_public_groups.sql -- Public group flag
-- --------------------------------------------------------------------------

ALTER TABLE conversations ADD COLUMN IF NOT EXISTS is_public BOOLEAN NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS idx_conversations_public ON conversations(is_public) WHERE is_public = true;

-- --------------------------------------------------------------------------
-- 007_avatars_and_groups.sql -- User avatars, group metadata, member roles
-- --------------------------------------------------------------------------

ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url TEXT;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS description TEXT;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS icon_url TEXT;
ALTER TABLE conversation_members ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'member';

-- --------------------------------------------------------------------------
-- 008_refresh_tokens.sql -- Refresh token storage
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON refresh_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_hash ON refresh_tokens(token_hash);

-- --------------------------------------------------------------------------
-- 009_performance_indexes.sql -- Query performance indexes
-- --------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_messages_conv_sender_created ON messages(conversation_id, sender_id, created_at);
CREATE INDEX IF NOT EXISTS idx_messages_conv_created_desc ON messages(conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reactions_msg_user ON reactions(message_id, user_id);
CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_id);

-- --------------------------------------------------------------------------
-- 010_message_edit_delete_blocks.sql -- Soft delete, editing, block list
-- --------------------------------------------------------------------------

ALTER TABLE messages ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS edited_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS blocked_users (
    blocker_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    blocked_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (blocker_id, blocked_id)
);
CREATE INDEX IF NOT EXISTS idx_blocked_users_blocked ON blocked_users(blocked_id);

-- --------------------------------------------------------------------------
-- 011_cascade_user_deletes.sql -- Add ON DELETE CASCADE to all user FKs
-- --------------------------------------------------------------------------

ALTER TABLE contacts DROP CONSTRAINT IF EXISTS contacts_requester_id_fkey;
ALTER TABLE contacts ADD CONSTRAINT contacts_requester_id_fkey
    FOREIGN KEY (requester_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE contacts DROP CONSTRAINT IF EXISTS contacts_target_id_fkey;
ALTER TABLE contacts ADD CONSTRAINT contacts_target_id_fkey
    FOREIGN KEY (target_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE conversation_members DROP CONSTRAINT IF EXISTS conversation_members_user_id_fkey;
ALTER TABLE conversation_members ADD CONSTRAINT conversation_members_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_sender_id_fkey;
ALTER TABLE messages ADD CONSTRAINT messages_sender_id_fkey
    FOREIGN KEY (sender_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE identity_keys DROP CONSTRAINT IF EXISTS identity_keys_user_id_fkey;
ALTER TABLE identity_keys ADD CONSTRAINT identity_keys_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE signed_prekeys DROP CONSTRAINT IF EXISTS signed_prekeys_user_id_fkey;
ALTER TABLE signed_prekeys ADD CONSTRAINT signed_prekeys_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE one_time_prekeys DROP CONSTRAINT IF EXISTS one_time_prekeys_user_id_fkey;
ALTER TABLE one_time_prekeys ADD CONSTRAINT one_time_prekeys_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE reactions DROP CONSTRAINT IF EXISTS reactions_user_id_fkey;
ALTER TABLE reactions ADD CONSTRAINT reactions_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE read_receipts DROP CONSTRAINT IF EXISTS read_receipts_user_id_fkey;
ALTER TABLE read_receipts ADD CONSTRAINT read_receipts_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE media DROP CONSTRAINT IF EXISTS media_uploader_id_fkey;
ALTER TABLE media ADD CONSTRAINT media_uploader_id_fkey
    FOREIGN KEY (uploader_id) REFERENCES users(id) ON DELETE CASCADE;

-- --------------------------------------------------------------------------
-- 012_user_profile.sql -- Bio and status message
-- --------------------------------------------------------------------------

ALTER TABLE users ADD COLUMN IF NOT EXISTS bio TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS status_message TEXT;

-- --------------------------------------------------------------------------
-- 013_signal_device_keys.sql -- Multi-device Signal Protocol support
-- --------------------------------------------------------------------------

ALTER TABLE identity_keys ADD COLUMN IF NOT EXISTS device_id INT NOT NULL DEFAULT 0;
ALTER TABLE identity_keys ADD COLUMN IF NOT EXISTS signing_key BYTEA;

-- Migrate identity_keys PK to composite (user_id, device_id)
-- Safe to run multiple times: DROP IF EXISTS handles re-runs
ALTER TABLE identity_keys DROP CONSTRAINT IF EXISTS identity_keys_pkey;
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'identity_keys'::regclass
          AND contype = 'p'
    ) THEN
        ALTER TABLE identity_keys ADD PRIMARY KEY (user_id, device_id);
    END IF;
END $$;

ALTER TABLE signed_prekeys ADD COLUMN IF NOT EXISTS device_id INT NOT NULL DEFAULT 0;

-- Migrate signed_prekeys PK to composite (user_id, device_id)
ALTER TABLE signed_prekeys DROP CONSTRAINT IF EXISTS signed_prekeys_pkey;
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'signed_prekeys'::regclass
          AND contype = 'p'
    ) THEN
        ALTER TABLE signed_prekeys ADD PRIMARY KEY (user_id, device_id);
    END IF;
END $$;

ALTER TABLE one_time_prekeys ADD COLUMN IF NOT EXISTS device_id INT NOT NULL DEFAULT 0;

-- --------------------------------------------------------------------------
-- 014_encryption_toggle.sql -- Per-conversation encryption flag
-- --------------------------------------------------------------------------

ALTER TABLE conversations ADD COLUMN IF NOT EXISTS is_encrypted BOOLEAN NOT NULL DEFAULT false;

-- --------------------------------------------------------------------------
-- 015_user_privacy_preferences.sql -- Read receipts and encryption prefs
-- --------------------------------------------------------------------------

ALTER TABLE users ADD COLUMN IF NOT EXISTS read_receipts_enabled BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE users ADD COLUMN IF NOT EXISTS allow_unencrypted_dm BOOLEAN NOT NULL DEFAULT true;

-- --------------------------------------------------------------------------
-- 016_channels_and_voice.sql -- Text/voice channels and voice sessions
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS channels (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('text', 'voice')),
    topic TEXT,
    position INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_channels_unique_name_active
    ON channels (conversation_id, lower(name))
    WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_channels_conversation_position
    ON channels (conversation_id, kind, position)
    WHERE deleted_at IS NULL;

ALTER TABLE messages ADD COLUMN IF NOT EXISTS channel_id UUID REFERENCES channels(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_messages_conversation_channel_created
    ON messages (conversation_id, channel_id, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS voice_sessions (
    channel_id UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    is_muted BOOLEAN NOT NULL DEFAULT false,
    is_deafened BOOLEAN NOT NULL DEFAULT false,
    push_to_talk BOOLEAN NOT NULL DEFAULT false,
    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_voice_sessions_channel ON voice_sessions (channel_id);

-- --------------------------------------------------------------------------
-- 017_media_conversation_id.sql -- Link media to conversations
-- --------------------------------------------------------------------------

ALTER TABLE media ADD COLUMN IF NOT EXISTS conversation_id UUID REFERENCES conversations(id);
CREATE INDEX IF NOT EXISTS idx_media_conversation ON media(conversation_id);

-- --------------------------------------------------------------------------
-- 018_audit_indexes.sql -- Additional query performance indexes
-- --------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_messages_deleted ON messages(deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_read_receipts_conv_user ON read_receipts(conversation_id, user_id);
CREATE INDEX IF NOT EXISTS idx_messages_channel ON messages(channel_id, created_at DESC) WHERE channel_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_messages_conv_unread ON messages(conversation_id, sender_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_voice_sessions_user ON voice_sessions(user_id);

-- --------------------------------------------------------------------------
-- 019_message_replies.sql -- Reply threading
-- --------------------------------------------------------------------------

ALTER TABLE messages ADD COLUMN IF NOT EXISTS reply_to_id UUID REFERENCES messages(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_messages_reply_to
    ON messages (reply_to_id)
    WHERE reply_to_id IS NOT NULL;

-- --------------------------------------------------------------------------
-- 020_message_search_and_mute.sql -- Full-text search and mute flag
-- --------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_messages_content_search
    ON messages USING GIN (to_tsvector('english', content))
    WHERE deleted_at IS NULL;

ALTER TABLE conversation_members ADD COLUMN IF NOT EXISTS is_muted BOOLEAN NOT NULL DEFAULT false;

-- --------------------------------------------------------------------------
-- 021_banned_members.sql -- Group ban system
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS banned_members (
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    banned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    banned_by UUID NOT NULL REFERENCES users(id),
    PRIMARY KEY (conversation_id, user_id)
);

-- --------------------------------------------------------------------------
-- 022_cleanup_empty_groups.sql -- One-time data cleanup (idempotent)
-- --------------------------------------------------------------------------

DELETE FROM voice_sessions WHERE channel_id IN (
    SELECT id FROM channels WHERE conversation_id IN (
        SELECT id FROM conversations
        WHERE kind = 'group'
          AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)
    )
);

DELETE FROM channels WHERE conversation_id IN (
    SELECT id FROM conversations
    WHERE kind = 'group'
      AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)
);

DELETE FROM messages WHERE conversation_id IN (
    SELECT id FROM conversations
    WHERE kind = 'group'
      AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)
);

DELETE FROM banned_members WHERE conversation_id IN (
    SELECT id FROM conversations
    WHERE kind = 'group'
      AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)
);

DELETE FROM read_receipts WHERE conversation_id IN (
    SELECT id FROM conversations
    WHERE kind = 'group'
      AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)
);

DELETE FROM media WHERE conversation_id IN (
    SELECT id FROM conversations
    WHERE kind = 'group'
      AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)
);

DELETE FROM conversations
WHERE kind = 'group'
  AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members);
