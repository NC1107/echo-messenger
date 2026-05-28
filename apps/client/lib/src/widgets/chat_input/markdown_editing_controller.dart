import 'package:flutter/widgets.dart';

import '../message/markdown_patterns.dart';

/// Opacity applied to markdown delimiter characters (e.g. `**`) when the
/// cursor or selection is adjacent to the formatting range.
const double _kDelimiterOpacity = 0.4;

/// A [TextEditingController] that renders markdown formatting inline in the
/// text field. The raw [text] (including all delimiter characters) is
/// unchanged — cursor positions and draft persistence work against the raw
/// string. Only the visual paint layer is affected via [buildTextSpan].
///
/// Supported inline patterns (matching [RichTextContent]):
///   **bold**, *italic*, ~~strikethrough~~, `inline code`
///
/// Cursor-aware delimiters: when the cursor/selection is NOT inside or
/// adjacent to a formatting range the delimiters are hidden (fontSize 0 /
/// transparent). When the cursor moves into or next to the range the
/// delimiters fade back in at [_kDelimiterOpacity] (Notion/Bear style).
///
/// Inline list bullets: lines starting with `- `, `* `, or `1.` at the
/// start of a line render the list marker as a styled glyph while leaving
/// the underlying raw text unchanged.
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
    final spans = _parseSpans(raw, baseStyle, selection);
    return TextSpan(children: spans, style: baseStyle);
  }

  // ---------------------------------------------------------------------------
  // Top-level orchestrator
  // ---------------------------------------------------------------------------

  /// Collect all non-overlapping formatting matches and build the span tree.
  List<InlineSpan> _parseSpans(String raw, TextStyle base, TextSelection sel) {
    // Handle list prefixes line-by-line first, then inline formatting within.
    final lines = raw.split('\n');
    if (lines.length == 1) {
      return _parseInlineSpans(raw, base, sel, offset: 0);
    }

    final spans = <InlineSpan>[];
    var lineStart = 0;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (i > 0) {
        spans.add(TextSpan(text: '\n', style: base));
        lineStart += 1; // account for \n consumed by split
      }
      spans.addAll(_parseInlineSpans(line, base, sel, offset: lineStart));
      lineStart += line.length;
    }
    return spans;
  }

  /// Parse a single logical line, replacing list markers with bullet glyphs
  /// and then applying inline formatting to the rest of the line.
  List<InlineSpan> _parseInlineSpans(
    String line,
    TextStyle base,
    TextSelection sel, {
    required int offset,
  }) {
    // Try to match a list prefix at the start of this line.
    final listMatch =
        mdUnorderedListPrefixRegex.firstMatch(line) ??
        mdOrderedListPrefixRegex.firstMatch(line);

    if (listMatch != null) {
      final isOrdered = mdOrderedListPrefixRegex.hasMatch(line);
      final rawPrefix = listMatch.group(0)!;
      final rest = line.substring(rawPrefix.length);

      // Render marker glyph + rest of line.
      final bulletStyle = base.copyWith(
        fontWeight: FontWeight.w600,
        color: (base.color ?? const Color(0xFFFFFFFF)).withValues(alpha: 0.7),
      );
      final bullet = isOrdered ? '${listMatch.group(1)!}. ' : '• '; // • glyph

      final prefixSpan = TextSpan(text: bullet, style: bulletStyle);
      // Hide raw marker chars but keep them in tree so offsets are preserved.
      final hiddenMarker = TextSpan(
        text: rawPrefix,
        style: base.copyWith(fontSize: 0, color: const Color(0x00000000)),
      );
      final restSpans = _collectFormattedSpans(
        rest,
        base,
        sel,
        offset: offset + rawPrefix.length,
      );
      // We overlay: hidden raw text + visible bullet glyph via WidgetSpan trick
      // is not possible in EditableText without WidgetSpan issues on cursor.
      // Instead: emit the bullet glyph as visible text (will be rendered) and
      // the raw marker as zero-size text. Order matters for cursor math — keep
      // raw first so cursor indices still map to the raw text.
      return [hiddenMarker, prefixSpan, ...restSpans];
    }

    return _collectFormattedSpans(line, base, sel, offset: offset);
  }

  // ---------------------------------------------------------------------------
  // Match collection
  // ---------------------------------------------------------------------------

  List<InlineSpan> _collectFormattedSpans(
    String raw,
    TextStyle base,
    TextSelection sel, {
    required int offset,
  }) {
    final entries = _collectMatches(raw, offset);
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
      spans.addAll(_spansForEntry(entry, base, sel));
      cursor = entry.end;
    }
    if (cursor < raw.length) {
      spans.add(TextSpan(text: raw.substring(cursor), style: base));
    }
    return spans;
  }

  List<_FormatEntry> _collectMatches(String raw, int offset) {
    final entries = <_FormatEntry>[];
    _addMatches(entries, raw, mdBoldRegex, _FormatTag.bold, offset);
    _addMatches(entries, raw, mdItalicRegex, _FormatTag.italic, offset);
    _addMatches(
      entries,
      raw,
      mdStrikethroughRegex,
      _FormatTag.strikethrough,
      offset,
    );
    _addMatches(entries, raw, mdInlineCodeRegex, _FormatTag.inlineCode, offset);

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
    int offset,
  ) {
    for (final m in regex.allMatches(raw)) {
      entries.add(
        _FormatEntry(
          start: m.start,
          end: m.end,
          // globalStart/End are positions in the original full `text` string.
          globalStart: m.start + offset,
          globalEnd: m.end + offset,
          tag: tag,
          match: m,
        ),
      );
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
  // Cursor-adjacency helpers
  // ---------------------------------------------------------------------------

  /// Returns true if [cursorPos] is strictly inside the open interval
  /// (rangeStart, rangeEnd) — i.e. past the opening delimiter and before
  /// the closing delimiter. Positions exactly at the outer boundaries do
  /// not trigger visibility (Notion/Bear style: delimiters appear once you
  /// move into the formatted region, not when hovering just outside).
  bool _isCursorInsideRange(int rangeStart, int rangeEnd, int cursorPos) {
    return cursorPos > rangeStart && cursorPos < rangeEnd;
  }

  /// Returns whether [sel] has any part strictly inside
  /// (globalStart, globalEnd).
  bool _selectionTouchesRange(
    TextSelection sel,
    int globalStart,
    int globalEnd,
  ) {
    final base = sel.baseOffset;
    final extent = sel.extentOffset;
    final lo = base < extent ? base : extent;
    final hi = base < extent ? extent : base;
    // Non-collapsed selection: show delimiters if any part of the selection
    // overlaps the interior of the range.
    if (lo != hi) {
      return lo < globalEnd && hi > globalStart;
    }
    // Collapsed cursor: strictly inside the range.
    return _isCursorInsideRange(globalStart, globalEnd, lo);
  }

  /// Resolves the style for a delimiter span. When the cursor/selection is
  /// adjacent to the owning format range, returns the dimmed delimiter style.
  /// Otherwise returns a fully transparent, zero-size style so the delimiter
  /// is visually hidden but its characters still occupy their raw positions.
  TextStyle _resolveDelimiterStyle(
    TextStyle bodyStyle,
    TextStyle base,
    int globalRangeStart,
    int globalRangeEnd,
    TextSelection sel,
  ) {
    final adjacent = _selectionTouchesRange(
      sel,
      globalRangeStart,
      globalRangeEnd,
    );
    if (adjacent) {
      final dimColor = (bodyStyle.color ?? base.color)?.withValues(
        alpha: _kDelimiterOpacity,
      );
      return bodyStyle.copyWith(color: dimColor);
    }
    // Fully hidden: zero font size and transparent color so cursor/layout are
    // unaffected (raw text still present in the string).
    return bodyStyle.copyWith(
      color: const Color(0x00000000),
      fontSize: 0,
      height: 0,
    );
  }

  // ---------------------------------------------------------------------------
  // Per-tag span builders
  // ---------------------------------------------------------------------------

  List<InlineSpan> _spansForEntry(
    _FormatEntry entry,
    TextStyle base,
    TextSelection sel,
  ) {
    return switch (entry.tag) {
      _FormatTag.bold => _emitBoldSpans(entry, base, sel),
      _FormatTag.italic => _emitItalicSpans(entry, base, sel),
      _FormatTag.strikethrough => _emitStrikethroughSpans(entry, base, sel),
      _FormatTag.inlineCode => _emitInlineCodeSpans(entry, base, sel),
    };
  }

  List<InlineSpan> _emitBoldSpans(
    _FormatEntry e,
    TextStyle base,
    TextSelection sel,
  ) {
    const delim = '**';
    final body = e.match.group(1)!;
    final boldStyle = base.copyWith(fontWeight: FontWeight.bold);
    return _delimBodyDelim(delim, body, delim, boldStyle, base, e, sel);
  }

  List<InlineSpan> _emitItalicSpans(
    _FormatEntry e,
    TextStyle base,
    TextSelection sel,
  ) {
    const delim = '*';
    final body = e.match.group(1)!;
    final italicStyle = base.copyWith(fontStyle: FontStyle.italic);
    return _delimBodyDelim(delim, body, delim, italicStyle, base, e, sel);
  }

  List<InlineSpan> _emitStrikethroughSpans(
    _FormatEntry e,
    TextStyle base,
    TextSelection sel,
  ) {
    const delim = '~~';
    final body = e.match.group(1)!;
    final strikeStyle = base.copyWith(decoration: TextDecoration.lineThrough);
    return _delimBodyDelim(delim, body, delim, strikeStyle, base, e, sel);
  }

  List<InlineSpan> _emitInlineCodeSpans(
    _FormatEntry e,
    TextStyle base,
    TextSelection sel,
  ) {
    const delim = '`';
    final body = e.match.group(1)!;
    final codeStyle = base.copyWith(fontFamily: 'monospace');
    return _delimBodyDelim(delim, body, delim, codeStyle, base, e, sel);
  }

  // ---------------------------------------------------------------------------
  // Generic delimiter + body + delimiter helper
  // ---------------------------------------------------------------------------

  /// Emits [prefix, body, suffix] as three [TextSpan]s.
  ///
  /// Delimiter visibility is determined by [_resolveDelimiterStyle]: when the
  /// cursor is not near the range, delimiters render at fontSize 0 (hidden);
  /// when near, they render at [_kDelimiterOpacity] (Notion/Bear style).
  List<TextSpan> _delimBodyDelim(
    String prefix,
    String body,
    String suffix,
    TextStyle bodyStyle,
    TextStyle base,
    _FormatEntry entry,
    TextSelection sel,
  ) {
    final delimStyle = _resolveDelimiterStyle(
      bodyStyle,
      base,
      entry.globalStart,
      entry.globalEnd,
      sel,
    );
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
    required this.globalStart,
    required this.globalEnd,
    required this.tag,
    required this.match,
  });

  /// Position within the current line segment being parsed.
  final int start;
  final int end;

  /// Position in the full raw [text] string (used for cursor adjacency).
  final int globalStart;
  final int globalEnd;

  final _FormatTag tag;
  final RegExpMatch match;
}
