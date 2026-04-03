DELETE FROM conversations
WHERE kind = 'group'
  AND id NOT IN (SELECT DISTINCT conversation_id FROM conversation_members);
