/// Check if a string looks like base64-encoded ciphertext.
///
/// Returns true if [text] is at least 20 characters long and consists
/// entirely of base64 alphabet characters (A-Z, a-z, 0-9, +, /, =).
/// Plaintext messages will almost never match this pattern.
bool looksEncrypted(String text) {
  if (text.length < 20) return false;
  return RegExp(r'^[A-Za-z0-9+/=]{20,}$').hasMatch(text);
}
