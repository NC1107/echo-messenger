-- Constrain conversations.kind to known values ('direct', 'group').
-- The column was added in the baseline migration as free-form TEXT;
-- this migration adds the CHECK constraint without changing any data.
-- If an unknown value exists the migration will fail loudly, which is
-- preferable to silently permitting corrupt state.
ALTER TABLE conversations
    ADD CONSTRAINT conversations_kind_check
    CHECK (kind IN ('direct', 'group'));
