import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import '../providers/auth_provider.dart';
import '../providers/server_url_provider.dart';
import '../theme/echo_theme.dart';

/// Overlay widget for searching messages within a conversation.
///
/// Shows a search text field with debounced input that queries
/// `GET /api/conversations/{id}/search?q={query}`. Results are displayed
/// in a scrollable dropdown list with username, content preview, and timestamp.
class MessageSearchOverlay extends ConsumerStatefulWidget {
  final String conversationId;
  final ValueChanged<String> onMessageSelected;
  final VoidCallback onClose;

  const MessageSearchOverlay({
    super.key,
    required this.conversationId,
    required this.onMessageSelected,
    required this.onClose,
  });

  @override
  ConsumerState<MessageSearchOverlay> createState() =>
      _MessageSearchOverlayState();
}

class _MessageSearchOverlayState extends ConsumerState<MessageSearchOverlay> {
  String _searchQuery = '';
  List<ChatMessage> _searchResults = const [];
  Timer? _searchDebounce;
  final _keyboardFocusNode = FocusNode();

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchQuery = '';
        _searchResults = const [];
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      _performSearch(query.trim());
    });
  }

  Future<void> _performSearch(String query) async {
    final serverUrl = ref.read(serverUrlProvider);
    final myUserId = ref.read(authProvider).userId ?? '';

    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.get(
              Uri.parse(
                '$serverUrl/api/conversations/${widget.conversationId}/search'
                '?q=${Uri.encodeQueryComponent(query)}',
              ),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final list = jsonDecode(response.body) as List;
        setState(() {
          _searchQuery = query;
          _searchResults = list
              .map(
                (e) => ChatMessage.fromServerJson(
                  e as Map<String, dynamic>,
                  myUserId,
                ),
              )
              .toList();
        });
      } else {
        setState(() {
          _searchQuery = query;
          _searchResults = const [];
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searchQuery = query;
        _searchResults = const [];
      });
    }
  }

  String _formatTimestamp(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);

      if (diff.inDays == 0) {
        final hour = dt.hour.toString().padLeft(2, '0');
        final minute = dt.minute.toString().padLeft(2, '0');
        return '$hour:$minute';
      } else if (diff.inDays < 7) {
        const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        return days[dt.weekday - 1];
      } else {
        final month = dt.month.toString().padLeft(2, '0');
        final day = dt.day.toString().padLeft(2, '0');
        return '$month/$day/${dt.year}';
      }
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _keyboardFocusNode,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onClose();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: context.surface,
          border: Border(bottom: BorderSide(color: context.border, width: 1)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              autofocus: true,
              style: TextStyle(fontSize: 14, color: context.textPrimary),
              decoration: InputDecoration(
                hintText: 'Search messages...',
                hintStyle: TextStyle(color: context.textMuted),
                prefixIcon: Icon(
                  Icons.search,
                  size: 18,
                  color: context.textMuted,
                ),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_searchQuery.isNotEmpty)
                      IconButton(
                        icon: Icon(
                          Icons.clear,
                          size: 16,
                          color: context.textMuted,
                        ),
                        onPressed: () {
                          setState(() {
                            _searchQuery = '';
                            _searchResults = const [];
                          });
                        },
                      ),
                    IconButton(
                      icon: Icon(
                        Icons.close,
                        size: 18,
                        color: context.textMuted,
                      ),
                      tooltip: 'Close search',
                      onPressed: widget.onClose,
                    ),
                  ],
                ),
                filled: true,
                fillColor: context.mainBg,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: context.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: context.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: context.accent),
                ),
              ),
              onChanged: _onSearchChanged,
            ),
            if (_searchResults.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _searchResults.length,
                  itemBuilder: (context, i) {
                    final r = _searchResults[i];
                    return InkWell(
                      onTap: () => widget.onMessageSelected(r.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    r.fromUsername,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: context.textSecondary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    r.content.length > 80
                                        ? '${r.content.substring(0, 80)}...'
                                        : r.content,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: context.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatTimestamp(r.timestamp),
                              style: TextStyle(
                                fontSize: 11,
                                color: context.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (_searchQuery.isNotEmpty && _searchResults.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'No results found',
                  style: TextStyle(fontSize: 12, color: context.textMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
