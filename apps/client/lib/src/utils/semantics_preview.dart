/// Builds a screen-reader-friendly preview string from raw message content.
///
/// - `[img:...]` attachments become "Image"
/// - `[file:...]` attachments become "File"
/// - `[voice:...]` attachments become "Voice message"
/// - Any other `[scheme:...]` token is stripped
/// - Whitespace is collapsed
/// - The result is truncated to 80 chars with an ellipsis when longer
String previewForSemantics(String content) {
  final stripped = content
      .replaceAll(RegExp(r'\[img:[^\]]*\]'), 'Image')
      .replaceAll(RegExp(r'\[file:[^\]]*\]'), 'File')
      .replaceAll(RegExp(r'\[voice:[^\]]*\]'), 'Voice message')
      .replaceAll(RegExp(r'\[\w+:[^\]]*\]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return stripped.length > 80 ? '${stripped.substring(0, 80)}…' : stripped;
}
