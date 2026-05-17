-- Add image dimensions to the media table so the client can reserve
-- the correct aspect-ratio placeholder before bytes arrive, eliminating
-- bubble-jump on image load.
--
-- Columns are nullable: non-image uploads (video, audio, documents) leave
-- them NULL, and legacy rows that pre-date this migration also remain NULL
-- (client falls back to the current fixed-height placeholder for those).

ALTER TABLE media
    ADD COLUMN IF NOT EXISTS width  INT NULL,
    ADD COLUMN IF NOT EXISTS height INT NULL;
