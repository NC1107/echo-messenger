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

  const GifPickerWidget({super.key, required this.onGifSelected});

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
    final items = (json['data'] as List?) ?? [];
    _results = items.map((item) {
      final file = item['file'] as Map<String, dynamic>? ?? {};
      return _GifItem(
        previewUrl: (file['gif'] as String?) ?? '',
        sendUrl: (file['mp4'] as String?) ?? (file['gif'] as String?) ?? '',
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
    return Container(
      height: 300,
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(top: BorderSide(color: context.border)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
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
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _results.isEmpty
                ? Center(
                    child: Text(
                      'No GIFs found',
                      style: TextStyle(color: context.textMuted),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 6,
                          mainAxisSpacing: 6,
                        ),
                    itemCount: _results.length,
                    itemBuilder: (ctx, i) {
                      final gif = _results[i];
                      return GestureDetector(
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
                      );
                    },
                  ),
          ),
        ],
      ),
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
