-- Clean up orphaned groups with zero members.
-- Must delete dependent rows first (messages, channels, read receipts, media refs)
-- before the conversation itself, because FK constraints are not all CASCADE.

WITH orphaned_groups AS (
  SELECT id FROM conversations
  WHERE kind = 'group'
    AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)
)
DELETE FROM voice_sessions WHERE channel_id IN (
  SELECT id FROM channels WHERE conversation_id IN (SELECT id FROM orphaned_groups)
);

WITH orphaned_groups AS (
  SELECT id FROM conversations
  WHERE kind = 'group'
    AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)
)
DELETE FROM channels WHERE conversation_id IN (SELECT id FROM orphaned_groups);

WITH orphaned_groups AS (
  SELECT id FROM conversations
  WHERE kind = 'group'
    AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)
)
DELETE FROM messages WHERE conversation_id IN (SELECT id FROM orphaned_groups);

WITH orphaned_groups AS (
  SELECT id FROM conversations
  WHERE kind = 'group'
    AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)
)
DELETE FROM banned_members WHERE conversation_id IN (SELECT id FROM orphaned_groups);

WITH orphaned_groups AS (
  SELECT id FROM conversations
  WHERE kind = 'group'
    AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)
)
DELETE FROM read_receipts WHERE conversation_id IN (SELECT id FROM orphaned_groups);

WITH orphaned_groups AS (
  SELECT id FROM conversations
  WHERE kind = 'group'
    AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members)
)
DELETE FROM media WHERE conversation_id IN (SELECT id FROM orphaned_groups);

DELETE FROM conversations
WHERE kind = 'group'
  AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members);
