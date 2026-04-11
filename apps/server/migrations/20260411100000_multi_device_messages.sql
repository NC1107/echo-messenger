-- Per-device ciphertexts for multi-device encrypted messaging.
-- When a sender encrypts for multiple recipient devices, each device's
-- ciphertext is stored here alongside the canonical message row.
CREATE TABLE IF NOT EXISTS message_device_contents (
    message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    device_id  INT  NOT NULL,
    content    TEXT NOT NULL,
    PRIMARY KEY (message_id, device_id)
);
