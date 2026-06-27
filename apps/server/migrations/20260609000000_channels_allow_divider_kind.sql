-- Channel context menu: allow a third channel kind, 'divider', used purely
-- as a visual separator in the channel bar (no messages, no voice). The
-- baseline table declared `CHECK (kind IN ('text', 'voice'))` inline, which
-- Postgres auto-named `channels_kind_check`. Widen it to admit 'divider'.
ALTER TABLE channels DROP CONSTRAINT IF EXISTS channels_kind_check;
ALTER TABLE channels
  ADD CONSTRAINT channels_kind_check
  CHECK (kind IN ('text', 'voice', 'divider'));
