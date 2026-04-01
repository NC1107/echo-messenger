-- Add ON DELETE CASCADE to all FK constraints referencing users(id)
-- so that DELETE FROM users WHERE id = $1 cascades properly.

-- contacts.requester_id
ALTER TABLE contacts DROP CONSTRAINT IF EXISTS contacts_requester_id_fkey;
ALTER TABLE contacts ADD CONSTRAINT contacts_requester_id_fkey
    FOREIGN KEY (requester_id) REFERENCES users(id) ON DELETE CASCADE;

-- contacts.target_id
ALTER TABLE contacts DROP CONSTRAINT IF EXISTS contacts_target_id_fkey;
ALTER TABLE contacts ADD CONSTRAINT contacts_target_id_fkey
    FOREIGN KEY (target_id) REFERENCES users(id) ON DELETE CASCADE;

-- conversation_members.user_id
ALTER TABLE conversation_members DROP CONSTRAINT IF EXISTS conversation_members_user_id_fkey;
ALTER TABLE conversation_members ADD CONSTRAINT conversation_members_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- messages.sender_id
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_sender_id_fkey;
ALTER TABLE messages ADD CONSTRAINT messages_sender_id_fkey
    FOREIGN KEY (sender_id) REFERENCES users(id) ON DELETE CASCADE;

-- identity_keys.user_id
ALTER TABLE identity_keys DROP CONSTRAINT IF EXISTS identity_keys_user_id_fkey;
ALTER TABLE identity_keys ADD CONSTRAINT identity_keys_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- signed_prekeys.user_id
ALTER TABLE signed_prekeys DROP CONSTRAINT IF EXISTS signed_prekeys_user_id_fkey;
ALTER TABLE signed_prekeys ADD CONSTRAINT signed_prekeys_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- one_time_prekeys.user_id
ALTER TABLE one_time_prekeys DROP CONSTRAINT IF EXISTS one_time_prekeys_user_id_fkey;
ALTER TABLE one_time_prekeys ADD CONSTRAINT one_time_prekeys_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- reactions.user_id
ALTER TABLE reactions DROP CONSTRAINT IF EXISTS reactions_user_id_fkey;
ALTER TABLE reactions ADD CONSTRAINT reactions_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- read_receipts.user_id
ALTER TABLE read_receipts DROP CONSTRAINT IF EXISTS read_receipts_user_id_fkey;
ALTER TABLE read_receipts ADD CONSTRAINT read_receipts_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- media.uploader_id
ALTER TABLE media DROP CONSTRAINT IF EXISTS media_uploader_id_fkey;
ALTER TABLE media ADD CONSTRAINT media_uploader_id_fkey
    FOREIGN KEY (uploader_id) REFERENCES users(id) ON DELETE CASCADE
