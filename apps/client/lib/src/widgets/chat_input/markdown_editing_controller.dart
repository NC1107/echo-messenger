import 'package:flutter/widgets.dart';

import '../message/markdown_patterns.dart';

/// Opacity applied to markdown delimiter characters (e.g. `**`) so the user
/// can still see them but formatted body text reads more prominently.
const double _kDelimiterOpacity = 0.4;

/// A [TextEditingController] that renders markdown formatting inline in the
/// text field. The raw [text] (including all delimiter characters) is
/// unchanged — cursor positions and draft persistence work against the raw
/// string. Only the visual paint layer is affected via [buildTextSpan].
///
/// Supported inline patterns (matching [RichTextContent]):
///   **bold**, *italic*, ~~strikethrough~~, `inline code`
///
/// Follow-up (#425): underline (__…__), spoiler (||…||), masked links,
/// fenced code blocks, blockquotes, headers, @mentions.
class MarkdownTextEditingController extends TextEditingController {
  MarkdownTextEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final raw = text;
    if (raw.isEmpty) {
      return TextSpan(text: '', style: style);
    }

    final baseStyle = style ?? const TextStyle();
    final spans = _parseSpans(raw, baseStyle);
    return TextSpan(children: spans, style: baseStyle);
  }

  // ---------------------------------------------------------------------------
  // Top-level orchestrator
  // ---------------------------------------------------------------------------

  /// Collect all non-overlapping formatting matches and build the span tree.
  List<InlineSpan> _parseSpans(String raw, TextStyle base) {
    final entries = _collectMatches(raw);
    final filtered = _filterOverlaps(entries);

    if (filtered.isEmpty) {
      return [TextSpan(text: raw, style: base)];
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final entry in filtered) {
      if (entry.start > cursor) {
        spans.add(
          TextSpan(text: raw.substring(cursor, entry.start), style: base),
        );
      }
      spans.addAll(_spansForEntry(entry, base));
      cursor = entry.end;
    }
    if (cursor < raw.length) {
      spans.add(TextSpan(text: raw.substring(cursor), style: base));
    }
    return spans;
  }

  // ---------------------------------------------------------------------------
  // Match collection
  // ---------------------------------------------------------------------------

  List<_FormatEntry> _collectMatches(String raw) {
    final entries = <_FormatEntry>[];
    _addMatches(entries, raw, mdBoldRegex, _FormatTag.bold);
    _addMatches(entries, raw, mdItalicRegex, _FormatTag.italic);
    _addMatches(entries, raw, mdStrikethroughRegex, _FormatTag.strikethrough);
    _addMatches(entries, raw, mdInlineCodeRegex, _FormatTag.inlineCode);

    entries.sort((a, b) {
      final cmp = a.start.compareTo(b.start);
      if (cmp != 0) return cmp;
      return b.end.compareTo(a.end); // wider match wins ties
    });
    return entries;
  }

  void _addMatches(
    List<_FormatEntry> entries,
    String raw,
    RegExp regex,
    _FormatTag tag,
  ) {
    for (final m in regex.allMatches(raw)) {
      entries.add(_FormatEntry(start: m.start, end: m.end, tag: tag, match: m));
    }
  }

  // ---------------------------------------------------------------------------
  // Overlap filtering
  // ---------------------------------------------------------------------------

  List<_FormatEntry> _filterOverlaps(List<_FormatEntry> entries) {
    final result = <_FormatEntry>[];
    var cursor = 0;
    for (final e in entries) {
      if (e.start < cursor) continue;
      result.add(e);
      cursor = e.end;
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Per-tag span builders
  // ---------------------------------------------------------------------------

  List<InlineSpan> _spansForEntry(_FormatEntry entry, TextStyle base) {
    return switch (entry.tag) {
      _FormatTag.bold => _emitBoldSpans(entry, base),
      _FormatTag.italic => _emitItalicSpans(entry, base),
      _FormatTag.strikethrough => _emitStrikethroughSpans(entry, base),
      _FormatTag.inlineCode => _emitInlineCodeSpans(entry, base),
    };
  }

  List<InlineSpan> _emitBoldSpans(_FormatEntry e, TextStyle base) {
    const delim = '**';
    final body = e.match.group(1)!;
    final boldStyle = base.copyWith(fontWeight: FontWeight.bold);
    return _delimBodyDelim(delim, body, delim, boldStyle, base);
  }

  List<InlineSpan> _emitItalicSpans(_FormatEntry e, TextStyle base) {
    const delim = '*';
    final body = e.match.group(1)!;
    final italicStyle = base.copyWith(fontStyle: FontStyle.italic);
    return _delimBodyDelim(delim, body, delim, italicStyle, base);
  }

  List<InlineSpan> _emitStrikethroughSpans(_FormatEntry e, TextStyle base) {
    const delim = '~~';
    final body = e.match.group(1)!;
    final strikeStyle = base.copyWith(decoration: TextDecoration.lineThrough);
    return _delimBodyDelim(delim, body, delim, strikeStyle, base);
  }

  List<InlineSpan> _emitInlineCodeSpans(_FormatEntry e, TextStyle base) {
    const delim = '`';
    final body = e.match.group(1)!;
    final codeStyle = base.copyWith(fontFamily: 'monospace');
    return _delimBodyDelim(delim, body, delim, codeStyle, base);
  }

  // ---------------------------------------------------------------------------
  // Generic delimiter + body + delimiter helper
  // ---------------------------------------------------------------------------

  /// Emits [prefix, body, suffix] as three [TextSpan]s where the delimiter
  /// spans inherit [bodyStyle] but at [_kDelimiterOpacity].
  List<TextSpan> _delimBodyDelim(
    String prefix,
    String body,
    String suffix,
    TextStyle bodyStyle,
    TextStyle base,
  ) {
    final dimColor = (bodyStyle.color ?? base.color)?.withValues(
      alpha: _kDelimiterOpacity,
    );
    final delimStyle = bodyStyle.copyWith(color: dimColor);
    return [
      TextSpan(text: prefix, style: delimStyle),
      TextSpan(text: body, style: bodyStyle),
      TextSpan(text: suffix, style: delimStyle),
    ];
  }
}

// ---------------------------------------------------------------------------
// Internal data types
// ---------------------------------------------------------------------------

enum _FormatTag { bold, italic, strikethrough, inlineCode }

class _FormatEntry {
  const _FormatEntry({
    required this.start,
    required this.end,
    required this.tag,
    required this.match,
  });

  final int start;
  final int end;
  final _FormatTag tag;
  final RegExpMatch match;
}
