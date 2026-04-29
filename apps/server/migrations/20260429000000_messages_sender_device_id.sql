-- #557: Track which device originated each message so multi-device replay
-- and history can address the correct per-device ratchet on the recipient.
ALTER TABLE messages ADD COLUMN sender_device_id INTEGER;
