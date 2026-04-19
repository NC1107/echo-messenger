ALTER TABLE users ADD COLUMN presence_status TEXT NOT NULL DEFAULT 'online'
  CHECK (presence_status IN ('online', 'away', 'dnd', 'invisible'));
