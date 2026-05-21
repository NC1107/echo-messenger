-- Admin dashboard Phase 1: bootstrap rule for fresh deployments.
--
-- The `users.is_admin` column already exists (see
-- 20260515000000_add_feedback_and_is_admin.sql).  The original convention
-- was "operator UPDATEs the row by hand"; that turns out to be a friction
-- point on first-boot for self-hosted instances, so the registration
-- handler now auto-promotes the very first registered user.
--
-- This migration handles the data side for existing deployments: if no
-- admin exists yet AND there is at least one user, promote the oldest
-- account.  Brand-new databases hit no rows and the registration handler
-- takes care of the first signup; both code paths agree on the same
-- invariant (exactly one bootstrap admin per fresh server).
--
-- The UPDATE is wrapped in a `WHERE NOT EXISTS (... is_admin)` guard so
-- it's safe to re-run.
UPDATE users
SET is_admin = TRUE
WHERE id = (
    SELECT id FROM users
    ORDER BY created_at ASC, id ASC
    LIMIT 1
)
AND NOT EXISTS (SELECT 1 FROM users WHERE is_admin = TRUE);
