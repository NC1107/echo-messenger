import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../theme/echo_theme.dart';

/// Data returned from the link preview API.
class LinkPreviewData {
  final String url;
  final String? title;
  final String? description;
  final String? image;
  final String? siteName;

  const LinkPreviewData({
    required this.url,
    this.title,
    this.description,
    this.image,
    this.siteName,
  });

  /// True when the preview has at least a title or description to show.
  bool get hasContent => title != null || description != null;
}

/// A compact card that displays OpenGraph metadata for a URL.
///
/// Results are cached in a static map so repeated renders of the same URL
/// do not trigger additional network requests.
class LinkPreviewCard extends StatefulWidget {
  final String url;
  final String serverUrl;
  final String token;

  const LinkPreviewCard({
    super.key,
    required this.url,
    required this.serverUrl,
    required this.token,
  });

  /// In-memory cache keyed by URL to avoid redundant fetches.
  /// Only successful results are cached. Evicts oldest entries beyond
  /// [_maxCacheSize] to prevent unbounded growth.
  static final Map<String, LinkPreviewData> _cache = {};
  static const int _maxCacheSize = 200;

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  LinkPreviewData? _data;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _fetchPreview();
  }

  Future<void> _fetchPreview() async {
    // Return cached result immediately.
    if (LinkPreviewCard._cache.containsKey(widget.url)) {
      if (mounted) {
        setState(() {
          _data = LinkPreviewCard._cache[widget.url];
          _loaded = true;
        });
      }
      return;
    }

    try {
      final response = await http
          .post(
            Uri.parse('${widget.serverUrl}/api/link-preview'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${widget.token}',
            },
            body: jsonEncode({'url': widget.url}),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final data = LinkPreviewData(
          url: json['url'] as String? ?? widget.url,
          title: json['title'] as String?,
          description: json['description'] as String?,
          image: json['image'] as String?,
          siteName: json['site_name'] as String?,
        );
        // Evict oldest entry when cache is full.
        if (LinkPreviewCard._cache.length >= LinkPreviewCard._maxCacheSize) {
          LinkPreviewCard._cache.remove(LinkPreviewCard._cache.keys.first);
        }
        LinkPreviewCard._cache[widget.url] = data;
        if (mounted) setState(() => _data = data);
      }
    } catch (_) {
      // Don't cache failures — allow retry on next render.
    }

    if (mounted) setState(() => _loaded = true);
  }

  void _openUrl() async {
    final uri = Uri.tryParse(widget.url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Show nothing while loading or on error / empty preview.
    if (!_loaded || _data == null || !_data!.hasContent) {
      return const SizedBox.shrink();
    }

    final data = _data!;
    final hasImage = data.image != null && data.image!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Semantics(
        label: 'Link preview for ${data.siteName ?? data.title ?? widget.url}',
        button: true,
        child: GestureDetector(
          onTap: _openUrl,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border(left: BorderSide(color: context.accent, width: 3)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasImage)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: Image.network(
                      data.image!,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (data.siteName != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            data.siteName!,
                            style: TextStyle(
                              fontSize: 11,
                              color: context.textMuted,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (data.title != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            data.title!,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: context.accent,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (data.description != null)
                        Text(
                          data.description!,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textSecondary,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
