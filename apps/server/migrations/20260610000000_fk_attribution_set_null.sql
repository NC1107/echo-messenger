-- Attribution FKs survive the referenced user's deletion instead of blocking it.
--
-- `group_keys.created_by` (the key rotator) and `banned_members.banned_by` (the
-- moderator who issued the ban) referenced users(id) with the default NO ACTION
-- + NOT NULL, so deleting a user who had created a group key or issued a ban
-- would fail with a foreign-key violation. These records must SURVIVE that
-- deletion -- the group key still protects past messages, the ban still applies
-- -- losing only the attribution. Switch both to nullable + ON DELETE SET NULL.
--
-- (group_invite_tokens.created_by intentionally keeps ON DELETE CASCADE: a
-- deleted user's invite link should disappear, not linger.)
--
-- Idempotent: drops + re-adds the same named constraints.

ALTER TABLE group_keys ALTER COLUMN created_by DROP NOT NULL;
ALTER TABLE group_keys DROP CONSTRAINT IF EXISTS group_keys_created_by_fkey;
ALTER TABLE group_keys
    ADD CONSTRAINT group_keys_created_by_fkey
    FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE banned_members ALTER COLUMN banned_by DROP NOT NULL;
ALTER TABLE banned_members DROP CONSTRAINT IF EXISTS banned_members_banned_by_fkey;
ALTER TABLE banned_members
    ADD CONSTRAINT banned_members_banned_by_fkey
    FOREIGN KEY (banned_by) REFERENCES users(id) ON DELETE SET NULL;
