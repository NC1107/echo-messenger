/// Builds a screen-reader-friendly preview string from raw message content.
/// Substitutes known attachment tokens, strips unknown ones, collapses
/// whitespace, and truncates to 80 chars + ellipsis when longer.
// Static patterns: Dart's RegExp is not memoised across calls, and this
// function runs on every message bubble build.  Promoting them out of the
// hot path saves ~5 RegExp allocations per call.
final RegExp _imgPattern = RegExp(r'\[img:[^\]]*\]');
final RegExp _filePattern = RegExp(r'\[file:[^\]]*\]');
final RegExp _voicePattern = RegExp(r'\[voice:[^\]]*\]');
final RegExp _videoPattern = RegExp(r'\[video:[^\]]*\]');
final RegExp _unknownTokenPattern = RegExp(r'\[\w+:[^\]]*\]');
final RegExp _whitespacePattern = RegExp(r'\s+');

String previewForSemantics(String content) {
  final stripped = content
      .replaceAll(_imgPattern, 'Image')
      .replaceAll(_filePattern, 'File')
      .replaceAll(_voicePattern, 'Voice message')
      .replaceAll(_videoPattern, 'Video')
      .replaceAll(_unknownTokenPattern, '')
      .replaceAll(_whitespacePattern, ' ')
      .trim();
  return stripped.length > 80 ? '${stripped.substring(0, 80)}…' : stripped;
}
