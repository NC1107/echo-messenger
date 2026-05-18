-- Audit P0 design doc, Phase 2 — downgrade-attack mitigation infrastructure.
--
-- The group-encryption wire format will gain a GRP2 variant that includes
-- a per-message Ed25519 sender signature. Without an in-envelope marker,
-- a hostile member (or man-in-the-middle on a compromised server) could
-- frame ciphertext as GRP1 to bypass the signature requirement — see
-- docs/group-e2e-design/04-migration-plan.md §"Downgrade-attack mitigation".
--
-- This column lets the rotator pin a minimum wire version for the key
-- version they produced. Receivers refuse to accept GRP1-prefixed wires
-- against a key version whose min_wire_version >= 2. Old key versions
-- stay at min_wire_version=1 so historical decrypt still works.
--
-- Default is 1 (the only wire version shipping today). When the GRP2
-- client lands, new rotations will write min_wire_version=2.

ALTER TABLE group_key_envelopes
    ADD COLUMN IF NOT EXISTS min_wire_version SMALLINT NOT NULL DEFAULT 1;

-- A CHECK guards against the most obvious value typos. We only know two
-- versions today (1 and 2); allowing 0 or negatives is always a bug. The
-- upper bound is generous so we don't have to revisit this when GRP3
-- ships. PostgreSQL doesn't support `ADD CONSTRAINT IF NOT EXISTS`, so
-- gate on a pg_constraint lookup for re-run safety.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'group_key_envelopes_min_wire_version_check'
    ) THEN
        ALTER TABLE group_key_envelopes
            ADD CONSTRAINT group_key_envelopes_min_wire_version_check
            CHECK (min_wire_version BETWEEN 1 AND 255);
    END IF;
END $$;
