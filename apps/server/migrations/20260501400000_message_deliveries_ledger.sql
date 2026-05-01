-- Per-device delivery ledger (#584).
--
-- messages.delivered is a coarse "any device received this" boolean used only
-- for sender-facing delivery ticks.  It cannot prevent a device that already
-- received an undecryptable placeholder from seeing the same placeholder again
-- on every reconnect (the message stays delivered=false so sibling devices can
-- still pick it up).
--
-- This table records exactly which (message, recipient_user, device) triples
-- have already been pushed to the wire.  get_undelivered filters them out per
-- connecting device, so each device sees each message at most once regardless
-- of how many times it reconnects.
CREATE TABLE IF NOT EXISTS message_deliveries (
    message_id        UUID      NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    recipient_user_id UUID      NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
    device_id         INT       NOT NULL,
    delivered_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (message_id, recipient_user_id, device_id)
);

-- Offline replay scans by (recipient_user_id, device_id); covering the
-- message_id avoids a heap fetch in the NOT EXISTS sub-select.
CREATE INDEX idx_msg_deliveries_device
    ON message_deliveries (recipient_user_id, device_id, message_id);
