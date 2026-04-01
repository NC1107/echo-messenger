-- User avatars
ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- Group descriptions and icons
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS description TEXT;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS icon_url TEXT;

-- Group member roles (owner, admin, member)
ALTER TABLE conversation_members ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'member';
