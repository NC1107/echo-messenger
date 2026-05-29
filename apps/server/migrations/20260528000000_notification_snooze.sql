-- Notification snooze: user can silence push for a chosen window.
-- NULL = not snoozed; populated = snoozed until that UTC timestamp.
-- The push send path checks this column before issuing an APNs alert
-- and lazily clears expired values so the table self-cleans.
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS notifications_snoozed_until TIMESTAMPTZ NULL;
