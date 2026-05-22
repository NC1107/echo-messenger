/// Check if a string looks like base64-encoded ciphertext.
///
/// Returns true if [text] is at least 20 characters long and consists
/// entirely of base64 alphabet characters (A-Z, a-z, 0-9, +, /, =), OR
/// if it carries one of the group-encrypted wire prefixes (`GRP1:`,
/// `GRP2:`). The prefixed cases are common in sidebar/last-message
/// previews when a client hasn't decrypted the message yet (e.g.
/// missing group key envelope) — we don't want the raw `GRP1:...`
/// blob leaking into the conversation list.
///
/// Plaintext messages will almost never match this pattern.
bool looksEncrypted(String text) {
  if (text.startsWith('GRP1:') || text.startsWith('GRP2:')) return true;
  if (text.length < 20) return false;
  return RegExp(r'^[A-Za-z0-9+/=]{20,}$').hasMatch(text);
}
