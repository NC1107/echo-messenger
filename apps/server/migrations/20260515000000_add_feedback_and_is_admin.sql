-- Beta-prep #4: in-app feedback inbox + an admin flag for the operator.
--
-- `users.is_admin` defaults to FALSE so this migration is safe on running
-- prod data; promotion is a one-off UPDATE the operator runs manually.
-- See `docs/dev-environment.md` for the bootstrap command.
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_admin BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS feedback (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  public_ok BOOLEAN NOT NULL DEFAULT FALSE,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'triaged', 'closed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- The admin inbox lists `open` reports newest-first; this composite index
-- backs the `WHERE status = $1 ORDER BY created_at DESC LIMIT $2` query
-- without touching the unfiltered hot path on `feedback(user_id, ...)` that
-- the per-user 24h rate-limit count needs.
CREATE INDEX IF NOT EXISTS feedback_status_created_at_idx
  ON feedback (status, created_at DESC);

CREATE INDEX IF NOT EXISTS feedback_user_id_created_at_idx
  ON feedback (user_id, created_at DESC);
