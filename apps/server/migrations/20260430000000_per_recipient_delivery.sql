-- Per-recipient delivery tracking (#351).
--
-- The global messages.delivered column marks a message delivered once ANY
-- recipient gets it live. In mixed online/offline group conversations this
-- causes offline members to permanently miss messages, because the offline
-- replay query (get_undelivered) used `delivered = false` as its filter and
-- found nothing once the first online recipient triggered the flag.
--
-- This table tracks delivery per (message_id, user_id, device_id):
--   device_id = 0  => unencrypted delivery to any device of this user
--                     (group messages, plaintext convs, legacy rows)
--   device_id > 0  => delivery to a specific device (encrypted per-device path)
--
-- The undelivered query now checks for absence of a receipt for the
-- reconnecting (user_id, device_id) pair instead of the global flag, so every
-- offline member can independently replay messages they missed.

CREATE TABLE message_delivery_receipts (
    message_id   UUID        NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id      UUID        NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
    device_id    INTEGER     NOT NULL DEFAULT 0,
    delivered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (message_id, user_id, device_id)
);

-- Speeds up the NOT EXISTS subquery in get_undelivered:
-- WHERE message_id = $msg AND user_id = $user AND (device_id = $dev OR device_id = 0)
CREATE INDEX idx_mdr_message_user ON message_delivery_receipts(message_id, user_id, device_id);
