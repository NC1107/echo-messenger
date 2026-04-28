-- Recipient-scope per-device ciphertexts (#522).
--
-- Per-user device_id values collide across users (every user starts at
-- device_id=1). The previous PRIMARY KEY (message_id, device_id) silently
-- dropped one of two ciphertexts whenever the sender's own device and a
-- recipient's device shared the same id, leading to undecryptable inbox state.
--
-- Pre-launch beta: TRUNCATE old rows. The canonical messages.content fallback
-- in deliver_undelivered_messages keeps replay working; existing offline
-- ciphertexts would be unrecoverable under the new key shape regardless.
TRUNCATE TABLE message_device_contents;

ALTER TABLE message_device_contents
    ADD COLUMN recipient_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE message_device_contents DROP CONSTRAINT message_device_contents_pkey;
ALTER TABLE message_device_contents
    ADD PRIMARY KEY (message_id, recipient_user_id, device_id);

DROP INDEX IF EXISTS idx_mdc_device;
CREATE INDEX idx_mdc_recipient ON message_device_contents(recipient_user_id, device_id);
