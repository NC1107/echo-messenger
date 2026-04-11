-- Add a functional index for case-insensitive username search.
CREATE INDEX IF NOT EXISTS idx_users_username_lower ON users(LOWER(username));
