-- Resumable / chunked upload sessions (#556).
--
-- A row is created per in-flight chunked upload and torn down once the
-- session is finalized into a `media` row, aborted by the client, or
-- swept by the background cleanup task (24h idle).  The `temp_path` is
-- always a UUID under `./uploads/.tmp/` -- never user-controlled, so a
-- compromised row cannot escape the uploads directory.
--
-- `status` is intentionally a TEXT column rather than a PG enum so future
-- statuses can be added without an enum migration.  Allowed values:
--   'pending'   -- bytes are still being received
--   'finalized' -- moved into ./uploads/ and a media row was created
--   'aborted'   -- swept by the cleanup task or explicitly cancelled
CREATE TABLE IF NOT EXISTS upload_sessions (
    id              UUID PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    filename        TEXT NOT NULL,
    mime_type       TEXT NOT NULL,
    total_size      BIGINT NOT NULL,
    bytes_received  BIGINT NOT NULL DEFAULT 0,
    conversation_id UUID REFERENCES conversations(id) ON DELETE SET NULL,
    temp_path       TEXT NOT NULL,
    status          TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The cleanup sweep filters on `(status, updated_at)` and per-user listings
-- filter on `(user_id, status)`.  The composite index covers both shapes.
CREATE INDEX IF NOT EXISTS idx_upload_sessions_user_status
    ON upload_sessions (user_id, status);

CREATE INDEX IF NOT EXISTS idx_upload_sessions_status_updated
    ON upload_sessions (status, updated_at);
