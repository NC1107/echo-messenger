-- Auto-attached diagnostic context on feedback submissions (#1159).
-- Older clients keep working; new columns are nullable.
ALTER TABLE feedback
  ADD COLUMN IF NOT EXISTS app_version TEXT,
  ADD COLUMN IF NOT EXISTS platform TEXT,
  ADD COLUMN IF NOT EXISTS logs TEXT;
