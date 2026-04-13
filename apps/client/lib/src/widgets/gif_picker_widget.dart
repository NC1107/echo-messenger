import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../theme/echo_theme.dart';

const _klipyAppKey =
    'jNYdV89ke1Svy4Kdvm6CHbPWuSb4bywKOTAAsDFGuffJj5xiJF4r7hAx0rNkPQV4';
const _klipyBase = 'https://api.klipy.com/api/v1/$_klipyAppKey/gifs';

class GifPickerWidget extends StatefulWidget {
  final void Function(String gifUrl, String? slug) onGifSelected;
  final VoidCallback? onClose;

  /// When true, removes the outer fixed-height container and border so the
  /// widget can be embedded inside a parent layout (e.g. a TabBarView).
  final bool embedMode;

  const GifPickerWidget({
    super.key,
    required this.onGifSelected,
    this.onClose,
    this.embedMode = false,
  });

  @override
  State<GifPickerWidget> createState() => _GifPickerWidgetState();
}

class _GifPickerWidgetState extends State<GifPickerWidget> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  List<_GifItem> _results = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadTrending();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadTrending() async {
    setState(() => _loading = true);
    try {
      final resp = await http.get(
        Uri.parse('$_klipyBase/trending?per_page=20'),
      );
      if (resp.statusCode == 200) {
        _parseResults(resp.body);
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      _loadTrending();
      return;
    }
    setState(() => _loading = true);
    try {
      final resp = await http.get(
        Uri.parse(
          '$_klipyBase/search?q=${Uri.encodeComponent(query)}&per_page=20',
        ),
      );
      if (resp.statusCode == 200) {
        _parseResults(resp.body);
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _parseResults(String body) {
    final json = jsonDecode(body);
    // Klipy nests items under data.data
    final outer = json['data'];
    final List items;
    if (outer is Map && outer['data'] is List) {
      items = outer['data'] as List;
    } else if (outer is List) {
      items = outer;
    } else {
      items = [];
    }
    _results = items.map((item) {
      final file = item['file'] as Map<String, dynamic>? ?? {};
      // file has hd/md sub-objects, each containing gif/mp4/webp etc.
      final md = file['md'] as Map<String, dynamic>? ?? {};
      final hd = file['hd'] as Map<String, dynamic>? ?? {};
      final previewGif =
          md['gif'] as Map<String, dynamic>? ??
          hd['gif'] as Map<String, dynamic>? ??
          {};
      final hdGif =
          hd['gif'] as Map<String, dynamic>? ??
          md['gif'] as Map<String, dynamic>? ??
          {};
      // Use .gif URLs for both preview and send so [img:] marker works
      return _GifItem(
        previewUrl: (previewGif['url'] as String?) ?? '',
        sendUrl:
            (hdGif['url'] as String?) ?? (previewGif['url'] as String?) ?? '',
        slug: (item['slug'] as String?) ?? '',
      );
    }).toList();
    if (mounted) setState(() {});
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _search(value);
    });
  }

  Future<void> _trackShare(String slug) async {
    if (slug.isEmpty) return;
    try {
      await http.post(Uri.parse('$_klipyBase/share/$slug'));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  style: TextStyle(fontSize: 14, color: context.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Search KLIPY',
                    hintStyle: TextStyle(color: context.textMuted),
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: context.textMuted,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: context.border),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 12,
                    ),
                    isDense: true,
                  ),
                ),
              ),
              if (!widget.embedMode) ...[
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: context.textMuted),
                  onPressed: widget.onClose,
                  tooltip: 'Close',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(child: _buildGifContent(context)),
      ],
    );

    if (widget.embedMode) return body;

    return Container(
      height: 300,
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(top: BorderSide(color: context.border)),
      ),
      child: body,
    );
  }

  Widget _buildGifContent(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          'No GIFs found',
          style: TextStyle(color: context.textMuted),
        ),
      );
    }
    final screenWidth = MediaQuery.of(context).size.width;
    final int crossAxisCount;
    final double spacing;
    if (screenWidth > 1200) {
      crossAxisCount = 5;
      spacing = 4;
    } else if (screenWidth >= 600) {
      crossAxisCount = 4;
      spacing = 4;
    } else {
      crossAxisCount = 2;
      spacing = 6;
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: spacing,
        mainAxisSpacing: spacing,
      ),
      itemCount: _results.length,
      itemBuilder: (ctx, i) {
        final gif = _results[i];
        return Semantics(
          label: 'send gif',
          image: true,
          button: true,
          child: GestureDetector(
            onTap: () {
              widget.onGifSelected(gif.sendUrl, gif.slug);
              _trackShare(gif.slug);
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                gif.previewUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, e, st) => Container(
                  color: context.mainBg,
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: context.textMuted,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GifItem {
  final String previewUrl;
  final String sendUrl;
  final String slug;

  const _GifItem({
    required this.previewUrl,
    required this.sendUrl,
    required this.slug,
  });
}
