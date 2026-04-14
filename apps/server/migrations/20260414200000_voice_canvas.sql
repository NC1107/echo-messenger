-- Persistent canvas state per voice channel.
-- Stores drawing strokes and images so the board is retained when users
-- leave and rejoin (like a Figma board that persists between sessions).

CREATE TABLE IF NOT EXISTS channel_canvas (
    channel_id   UUID PRIMARY KEY REFERENCES channels(id) ON DELETE CASCADE,
    drawing_data JSONB NOT NULL DEFAULT '[]',
    images_data  JSONB NOT NULL DEFAULT '[]',
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
