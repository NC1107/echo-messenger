import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Regex for detecting URLs in message text.
final urlRegex = RegExp(r'https?://[^\s]+');

/// Regex for detecting fenced code blocks: ```\n...\n``` (multiline).
final _codeBlockRegex = RegExp(r'```\n?([\s\S]*?)```', multiLine: true);

/// Regex for detecting inline code: `...` (single backtick, no nesting).
final _inlineCodeRegex = RegExp(r'`([^`\n]+)`');

/// Regex for detecting bold text: **...**
final _boldRegex = RegExp(r'\*\*(.+?)\*\*');

/// Regex for detecting italic text: *...*
/// Negative lookahead/lookbehind to avoid matching ** (bold delimiters).
final _italicRegex = RegExp(r'(?<!\*)\*([^*]+?)\*(?!\*)');

/// Regex for detecting underline text: __...__
/// Negative lookahead/lookbehind to avoid matching bold+italic combos.
final _underlineRegex = RegExp(r'(?<!_)__([^_]+?)__(?!_)');

/// Regex for detecting strikethrough text: ~~...~~
final _strikethroughRegex = RegExp(r'~~(.+?)~~');

/// Regex for detecting spoiler text: ||...||
final _spoilerRegex = RegExp(r'\|\|(.+?)\|\|');

/// Regex for detecting masked links: [text](url)
final _maskedLinkRegex = RegExp(r'\[([^\]]+)\]\((https?://[^\s)]+)\)');

/// Regex for detecting @mentions in message text.
final _mentionRegex = RegExp(r'@(\w+)');

/// A widget that renders message text with Discord-style markdown formatting,
/// clickable URLs, and @mentions with accent styling.
///
/// Precedence: code blocks > blockquotes > headers > lists > inline code >
/// bold > italic > underline > strikethrough > spoiler > masked links >
/// URLs > mentions.
class RichTextContent extends StatefulWidget {
  final String text;
  final Color textColor;
  final Color accentHoverColor;
  final Color textSecondaryColor;

  const RichTextContent({
    super.key,
    required this.text,
    required this.textColor,
    required this.accentHoverColor,
    required this.textSecondaryColor,
  });

  @override
  State<RichTextContent> createState() => _RichTextContentState();
}

class _RichTextContentState extends State<RichTextContent> {
  final List<TapGestureRecognizer> _linkRecognizers = [];

  @override
  void dispose() {
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    super.dispose();
  }

  /// Base text style used throughout message rendering.
  TextStyle _baseStyle() =>
      TextStyle(fontSize: 15, color: widget.textColor, height: 1.47);

  TapGestureRecognizer _createLinkRecognizer(String url) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () async {
        final uri = Uri.tryParse(url);
        if (uri != null && await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      };
    _linkRecognizers.add(recognizer);
    return recognizer;
  }

  /// Build spans for plain text that may contain @mentions.
  List<InlineSpan> _buildMentionSpans(String text) {
    final mentionMatches = _mentionRegex.allMatches(text).toList();
    if (mentionMatches.isEmpty) {
      return [TextSpan(text: text, style: _baseStyle())];
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;
    for (final match in mentionMatches) {
      if (match.start > lastEnd) {
        spans.add(
          TextSpan(
            text: text.substring(lastEnd, match.start),
            style: _baseStyle(),
          ),
        );
      }
      spans.add(
        TextSpan(
          text: match.group(0),
          style: TextStyle(
            fontSize: 15,
            color: widget.accentHoverColor,
            fontWeight: FontWeight.w600,
            height: 1.47,
          ),
        ),
      );
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd), style: _baseStyle()));
    }
    return spans;
  }

  /// Build spans for a segment that may contain bold, italic, underline,
  /// strikethrough, spoiler, masked links, URLs, and mentions (but NOT code).
  List<InlineSpan> _buildFormattedSpans(String text) {
    final entries = <({int start, int end, String tag, RegExpMatch match})>[];

    for (final m in _maskedLinkRegex.allMatches(text)) {
      entries.add((start: m.start, end: m.end, tag: 'masked_link', match: m));
    }
    for (final m in _boldRegex.allMatches(text)) {
      entries.add((start: m.start, end: m.end, tag: 'bold', match: m));
    }
    for (final m in _italicRegex.allMatches(text)) {
      entries.add((start: m.start, end: m.end, tag: 'italic', match: m));
    }
    for (final m in _underlineRegex.allMatches(text)) {
      entries.add((start: m.start, end: m.end, tag: 'underline', match: m));
    }
    for (final m in _strikethroughRegex.allMatches(text)) {
      entries.add((start: m.start, end: m.end, tag: 'strikethrough', match: m));
    }
    for (final m in _spoilerRegex.allMatches(text)) {
      entries.add((start: m.start, end: m.end, tag: 'spoiler', match: m));
    }
    for (final m in urlRegex.allMatches(text)) {
      entries.add((start: m.start, end: m.end, tag: 'url', match: m));
    }

    entries.sort((a, b) {
      final cmp = a.start.compareTo(b.start);
      if (cmp != 0) return cmp;
      return b.end.compareTo(a.end);
    });

    final filtered = <({int start, int end, String tag, RegExpMatch match})>[];
    int cursor = 0;
    for (final e in entries) {
      if (e.start < cursor) continue;
      filtered.add(e);
      cursor = e.end;
    }

    if (filtered.isEmpty) {
      return _buildMentionSpans(text);
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final e in filtered) {
      if (e.start > lastEnd) {
        spans.addAll(_buildMentionSpans(text.substring(lastEnd, e.start)));
      }

      switch (e.tag) {
        case 'bold':
          final inner = e.match.group(1)!;
          spans.add(
            TextSpan(
              text: inner,
              style: _baseStyle().copyWith(fontWeight: FontWeight.bold),
            ),
          );
        case 'italic':
          final inner = e.match.group(1)!;
          spans.add(
            TextSpan(
              text: inner,
              style: _baseStyle().copyWith(fontStyle: FontStyle.italic),
            ),
          );
        case 'underline':
          final inner = e.match.group(1)!;
          spans.add(
            TextSpan(
              text: inner,
              style: _baseStyle().copyWith(
                decoration: TextDecoration.underline,
                decorationColor: widget.textColor,
              ),
            ),
          );
        case 'strikethrough':
          final inner = e.match.group(1)!;
          spans.add(
            TextSpan(
              text: inner,
              style: _baseStyle().copyWith(
                decoration: TextDecoration.lineThrough,
                decorationColor: widget.textColor,
              ),
            ),
          );
        case 'spoiler':
          final inner = e.match.group(1)!;
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _SpoilerText(
                text: inner,
                style: _baseStyle(),
                bgColor: widget.textSecondaryColor,
              ),
            ),
          );
        case 'masked_link':
          final linkText = e.match.group(1)!;
          final url = e.match.group(2)!;
          spans.add(
            TextSpan(
              text: linkText,
              style: TextStyle(
                fontSize: 15,
                color: widget.accentHoverColor,
                decoration: TextDecoration.underline,
                decorationColor: widget.accentHoverColor,
                height: 1.47,
              ),
              recognizer: _createLinkRecognizer(url),
            ),
          );
        case 'url':
          final url = e.match.group(0)!;
          spans.add(
            TextSpan(
              text: url,
              style: TextStyle(
                fontSize: 15,
                color: widget.accentHoverColor,
                decoration: TextDecoration.underline,
                decorationColor: widget.accentHoverColor,
                height: 1.47,
              ),
              recognizer: _createLinkRecognizer(url),
            ),
          );
      }

      lastEnd = e.end;
    }

    if (lastEnd < text.length) {
      spans.addAll(_buildMentionSpans(text.substring(lastEnd)));
    }

    return spans;
  }

  /// Build spans for a segment that may contain inline code, bold, italic,
  /// underline, strikethrough, spoiler, masked links, URLs, and mentions
  /// (but NOT fenced code blocks).
  List<InlineSpan> _buildInlineCodeAndFormatting(String text) {
    final inlineCodeMatches = _inlineCodeRegex.allMatches(text).toList();
    if (inlineCodeMatches.isEmpty) {
      return _buildFormattedSpans(text);
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in inlineCodeMatches) {
      if (match.start > lastEnd) {
        spans.addAll(
          _buildFormattedSpans(text.substring(lastEnd, match.start)),
        );
      }

      final code = match.group(1)!;
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: widget.textSecondaryColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              code,
              style: TextStyle(
                fontSize: 14,
                fontFamily: 'monospace',
                color: widget.textColor,
                height: 1.47,
              ),
            ),
          ),
        ),
      );

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      spans.addAll(_buildFormattedSpans(text.substring(lastEnd)));
    }

    return spans;
  }

  /// Parse a header line (# / ## / ###) and return the widget.
  Widget _buildHeader(String line) {
    int level = 0;
    if (line.startsWith('### ')) {
      level = 3;
    } else if (line.startsWith('## ')) {
      level = 2;
    } else if (line.startsWith('# ')) {
      level = 1;
    }

    final content = line.substring(level + 1);
    final fontSize = switch (level) {
      1 => 24.0,
      2 => 20.0,
      _ => 17.0,
    };

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: RichText(
        text: TextSpan(
          children: _buildInlineCodeAndFormatting(content),
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            color: widget.textColor,
            height: 1.35,
          ),
        ),
      ),
    );
  }

  /// Build a blockquote widget from lines prefixed with > or >>>.
  Widget _buildBlockquote(List<String> lines) {
    // Strip the > prefix from each line
    final content = lines
        .map((l) {
          if (l.startsWith('>>> ')) return l.substring(4);
          if (l.startsWith('> ')) return l.substring(2);
          if (l.startsWith('>')) return l.substring(1);
          return l;
        })
        .join('\n');

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: widget.textSecondaryColor.withValues(alpha: 0.4),
            width: 3,
          ),
        ),
      ),
      child: RichText(
        text: TextSpan(children: _buildInlineCodeAndFormatting(content)),
      ),
    );
  }

  /// Build a list widget (ordered or unordered) from consecutive list lines.
  Widget _buildList(List<String> lines, bool ordered) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < lines.length; i++)
            _buildListItem(lines[i], ordered, i + 1),
        ],
      ),
    );
  }

  Widget _buildListItem(String line, bool ordered, int index) {
    // Strip the list prefix
    String content;
    if (ordered) {
      // Match "1. ", "2. ", etc.
      final match = RegExp(r'^\d+\.\s').firstMatch(line);
      content = match != null ? line.substring(match.end) : line;
    } else {
      // Match "- " or "* "
      final match = RegExp(r'^[-*]\s').firstMatch(line);
      content = match != null ? line.substring(match.end) : line;
    }

    final bullet = ordered ? '$index.' : '\u2022';

    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 1, bottom: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: ordered ? 24 : 16,
            child: Text(
              bullet,
              style: _baseStyle().copyWith(color: widget.textSecondaryColor),
            ),
          ),
          Expanded(
            child: RichText(
              text: TextSpan(children: _buildInlineCodeAndFormatting(content)),
            ),
          ),
        ],
      ),
    );
  }

  /// Build a subtext line (-# prefix, Discord-style small dimmed text).
  Widget _buildSubtext(String line) {
    final content = line.substring(3); // Strip "-# "
    return Padding(
      padding: const EdgeInsets.only(top: 1, bottom: 1),
      child: RichText(
        text: TextSpan(
          children: _buildInlineCodeAndFormatting(content),
          style: TextStyle(
            fontSize: 12,
            color: widget.textSecondaryColor,
            height: 1.47,
          ),
        ),
      ),
    );
  }

  static final _headerRegex = RegExp(r'^#{1,3} ');
  static final _unorderedListRegex = RegExp(r'^[-*] ');
  static final _orderedListRegex = RegExp(r'^\d+\. ');
  static final _blockquoteRegex = RegExp(r'^>{1,3} ?');
  static final _subtextRegex = RegExp(r'^-# ');

  @override
  Widget build(BuildContext context) {
    // Dispose old recognizers on each rebuild
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    _linkRecognizers.clear();

    final text = widget.text;
    final textColor = widget.textColor;

    // Check for fenced code blocks first (highest precedence).
    final codeBlockMatches = _codeBlockRegex.allMatches(text).toList();

    // If no code blocks and no block-level syntax, fast path
    if (codeBlockMatches.isEmpty && !_hasBlockSyntax(text)) {
      final hasUrl = urlRegex.hasMatch(text);
      final hasMention = _mentionRegex.hasMatch(text);
      final hasBold = _boldRegex.hasMatch(text);
      final hasItalic = _italicRegex.hasMatch(text);
      final hasInlineCode = _inlineCodeRegex.hasMatch(text);
      final hasUnderline = _underlineRegex.hasMatch(text);
      final hasStrikethrough = _strikethroughRegex.hasMatch(text);
      final hasSpoiler = _spoilerRegex.hasMatch(text);
      final hasMaskedLink = _maskedLinkRegex.hasMatch(text);

      if (!hasUrl &&
          !hasMention &&
          !hasBold &&
          !hasItalic &&
          !hasInlineCode &&
          !hasUnderline &&
          !hasStrikethrough &&
          !hasSpoiler &&
          !hasMaskedLink) {
        return Text(
          text,
          style: TextStyle(fontSize: 15, color: textColor, height: 1.47),
        );
      }

      return RichText(
        text: TextSpan(children: _buildInlineCodeAndFormatting(text)),
      );
    }

    // Complex path: split into segments around code blocks, then parse
    // block-level syntax (headers, lists, blockquotes) from remaining text.
    final children = <Widget>[];
    int lastEnd = 0;

    for (final match in codeBlockMatches) {
      if (match.start > lastEnd) {
        final segment = text.substring(lastEnd, match.start);
        children.addAll(_parseBlockSegment(segment));
      }

      final code = (match.group(1) ?? '').trimRight();
      children.add(
        _CodeBlockWidget(
          code: code,
          bgColor: widget.textSecondaryColor.withValues(alpha: 0.12),
          textColor: textColor,
        ),
      );

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      final segment = text.substring(lastEnd);
      children.addAll(_parseBlockSegment(segment));
    }

    if (children.length == 1) return children.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// Check if text contains any block-level markdown syntax.
  bool _hasBlockSyntax(String text) {
    final lines = text.split('\n');
    for (final line in lines) {
      final trimmed = line.trimLeft();
      if (_headerRegex.hasMatch(trimmed) ||
          _unorderedListRegex.hasMatch(trimmed) ||
          _orderedListRegex.hasMatch(trimmed) ||
          _blockquoteRegex.hasMatch(trimmed) ||
          _subtextRegex.hasMatch(trimmed)) {
        return true;
      }
    }
    return false;
  }

  /// Parse a text segment (between code blocks) into block-level widgets.
  List<Widget> _parseBlockSegment(String segment) {
    final trimmed = segment.trim();
    if (trimmed.isEmpty) return [];

    final lines = trimmed.split('\n');
    final widgets = <Widget>[];

    // Handle ">>> " multi-line blockquote (everything after >>> is quoted)
    if (trimmed.startsWith('>>> ')) {
      widgets.add(_buildBlockquote([trimmed]));
      return widgets;
    }

    int i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final stripped = line.trimLeft();

      // Header
      if (_headerRegex.hasMatch(stripped)) {
        widgets.add(_buildHeader(stripped));
        i++;
        continue;
      }

      // Subtext (-#)
      if (_subtextRegex.hasMatch(stripped)) {
        widgets.add(_buildSubtext(stripped));
        i++;
        continue;
      }

      // Blockquote (collect consecutive > lines)
      if (stripped.startsWith('> ') || stripped.startsWith('>')) {
        final quoteLines = <String>[];
        while (i < lines.length) {
          final ql = lines[i].trimLeft();
          if (ql.startsWith('> ') || ql.startsWith('>')) {
            quoteLines.add(ql);
            i++;
          } else {
            break;
          }
        }
        widgets.add(_buildBlockquote(quoteLines));
        continue;
      }

      // Unordered list (collect consecutive - or * lines)
      if (_unorderedListRegex.hasMatch(stripped)) {
        final listLines = <String>[];
        while (i < lines.length) {
          final ll = lines[i].trimLeft();
          if (_unorderedListRegex.hasMatch(ll)) {
            listLines.add(ll);
            i++;
          } else {
            break;
          }
        }
        widgets.add(_buildList(listLines, false));
        continue;
      }

      // Ordered list (collect consecutive numbered lines)
      if (_orderedListRegex.hasMatch(stripped)) {
        final listLines = <String>[];
        while (i < lines.length) {
          final ll = lines[i].trimLeft();
          if (_orderedListRegex.hasMatch(ll)) {
            listLines.add(ll);
            i++;
          } else {
            break;
          }
        }
        widgets.add(_buildList(listLines, true));
        continue;
      }

      // Plain text line -- collect consecutive plain lines into one RichText
      final plainLines = <String>[];
      while (i < lines.length) {
        final pl = lines[i].trimLeft();
        if (_headerRegex.hasMatch(pl) ||
            _unorderedListRegex.hasMatch(pl) ||
            _orderedListRegex.hasMatch(pl) ||
            _blockquoteRegex.hasMatch(pl) ||
            _subtextRegex.hasMatch(pl)) {
          break;
        }
        plainLines.add(lines[i]);
        i++;
      }

      if (plainLines.isNotEmpty) {
        final joined = plainLines.join('\n');
        if (joined.trim().isNotEmpty) {
          widgets.add(
            RichText(
              text: TextSpan(children: _buildInlineCodeAndFormatting(joined)),
            ),
          );
        }
      }
    }

    return widgets;
  }
}

/// A spoiler text widget that reveals content on tap.
class _SpoilerText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Color bgColor;

  const _SpoilerText({
    required this.text,
    required this.style,
    required this.bgColor,
  });

  @override
  State<_SpoilerText> createState() => _SpoilerTextState();
}

class _SpoilerTextState extends State<_SpoilerText> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _revealed = !_revealed),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: _revealed
              ? widget.bgColor.withValues(alpha: 0.15)
              : widget.bgColor.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          widget.text,
          style: widget.style.copyWith(
            color: _revealed ? widget.style.color : Colors.transparent,
          ),
        ),
      ),
    );
  }
}

/// A code block widget with a hover-reveal "Copy" button.
class _CodeBlockWidget extends StatefulWidget {
  final String code;
  final Color bgColor;
  final Color textColor;

  const _CodeBlockWidget({
    required this.code,
    required this.bgColor,
    required this.textColor,
  });

  @override
  State<_CodeBlockWidget> createState() => _CodeBlockWidgetState();
}

class _CodeBlockWidgetState extends State<_CodeBlockWidget> {
  bool _hovered = false;
  bool _copied = false;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: widget.bgColor,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              widget.code,
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                color: widget.textColor,
                height: 1.5,
              ),
            ),
          ),
          if (_hovered || _copied)
            Positioned(
              top: 8,
              right: 8,
              child: GestureDetector(
                onTap: _copy,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: widget.bgColor,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: widget.textColor.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Text(
                    _copied ? 'Copied!' : 'Copy',
                    style: TextStyle(
                      fontSize: 11,
                      color: widget.textColor.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
