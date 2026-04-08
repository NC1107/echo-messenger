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

/// Regex for detecting @mentions in message text.
final _mentionRegex = RegExp(r'@(\w+)');

/// A widget that renders message text with markdown formatting, clickable
/// URLs, and @mentions with accent styling.
///
/// Precedence: code blocks > inline code > bold > italic > URLs > mentions.
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

  /// Build spans for a segment that may contain bold, italic, URLs, and
  /// mentions (but NOT code -- code is stripped before this is called).
  List<InlineSpan> _buildFormattedSpans(String text) {
    final entries = <({int start, int end, String tag, RegExpMatch match})>[];

    for (final m in _boldRegex.allMatches(text)) {
      entries.add((start: m.start, end: m.end, tag: 'bold', match: m));
    }
    for (final m in _italicRegex.allMatches(text)) {
      entries.add((start: m.start, end: m.end, tag: 'italic', match: m));
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
  /// URLs, and mentions (but NOT fenced code blocks).
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

    if (codeBlockMatches.isEmpty) {
      final hasUrl = urlRegex.hasMatch(text);
      final hasMention = _mentionRegex.hasMatch(text);
      final hasBold = _boldRegex.hasMatch(text);
      final hasItalic = _italicRegex.hasMatch(text);
      final hasInlineCode = _inlineCodeRegex.hasMatch(text);

      if (!hasUrl && !hasMention && !hasBold && !hasItalic && !hasInlineCode) {
        return Text(
          text,
          style: TextStyle(fontSize: 15, color: textColor, height: 1.47),
        );
      }

      return RichText(
        text: TextSpan(children: _buildInlineCodeAndFormatting(text)),
      );
    }

    // Has code blocks -- build a Column with interleaved text and code blocks.
    final children = <Widget>[];
    int lastEnd = 0;

    for (final match in codeBlockMatches) {
      if (match.start > lastEnd) {
        final segment = text.substring(lastEnd, match.start);
        if (segment.trim().isNotEmpty) {
          children.add(
            RichText(
              text: TextSpan(
                children: _buildInlineCodeAndFormatting(segment.trim()),
              ),
            ),
          );
        }
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
      if (segment.trim().isNotEmpty) {
        children.add(
          RichText(
            text: TextSpan(
              children: _buildInlineCodeAndFormatting(segment.trim()),
            ),
          ),
        );
      }
    }

    if (children.length == 1) return children.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
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
