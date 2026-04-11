-- Index for device-centric queries on multi-device message ciphertexts.
CREATE INDEX IF NOT EXISTS idx_mdc_device ON message_device_contents(device_id);
