-- Server identity metadata. Holds a stable UUID minted at first boot so
-- clients can pin "the same server" across hostname changes (e.g.
-- family.lan -> family.example.com). Singleton: a UNIQUE constraint on
-- the sentinel column prevents two concurrent INSERTs from both succeeding
-- and producing different server_ids.
CREATE TABLE IF NOT EXISTS server_metadata (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE,
    id UUID NOT NULL DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT server_metadata_singleton_chk CHECK (singleton = TRUE)
);
