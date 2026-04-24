import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';
import '../utils/fuzzy_score.dart';

/// Global message search overlay (Ctrl+Shift+F or search icon).
///
/// Searches messages across ALL conversations the user is a member of,
/// using the server's full-text search endpoint (GIN index on messages).
class GlobalSearchOverlay extends ConsumerStatefulWidget {
  final void Function(String conversationId, String messageId) onResultTap;

  const GlobalSearchOverlay({super.key, required this.onResultTap});

  @override
  ConsumerState<GlobalSearchOverlay> createState() =>
      _GlobalSearchOverlayState();
}

class _GlobalSearchOverlayState extends ConsumerState<GlobalSearchOverlay> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _keyboardFocusNode = FocusNode();
  Timer? _debounce;
  List<_SearchResult> _results = [];
  bool _loading = false;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _keyboardFocusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 2) {
      setState(() {
        _results = [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _search(query.trim());
    });
  }

  Future<void> _search(String query) async {
    if (query == _lastQuery) return;
    _lastQuery = query;

    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token ?? '';
    final uri = Uri.parse(
      '$serverUrl/api/messages/search?q=${Uri.encodeQueryComponent(query)}&limit=20',
    );

    try {
      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        final list = jsonDecode(response.body) as List;
        final conversations = ref.read(conversationsProvider).conversations;
        final myUserId = ref.read(authProvider).userId ?? '';
        final parsed = list.map((item) {
          final e = item as Map<String, dynamic>;
          final convId = (e['conversation_id'] ?? '').toString();
          final conv = conversations.where((c) => c.id == convId).firstOrNull;
          return _SearchResult(
            messageId: (e['message_id'] ?? '').toString(),
            conversationId: convId,
            conversationName: conv?.displayName(myUserId) ?? 'Unknown',
            senderUsername: (e['sender_username'] ?? '').toString(),
            content: (e['content'] ?? '').toString(),
            timestamp: (e['created_at'] ?? '').toString(),
          );
        }).toList();
        parsed.sort((a, b) {
          final sa =
              fuzzyScore(query, a.content) +
              0.5 * fuzzyScore(query, a.conversationName) +
              0.25 * fuzzyScore(query, a.senderUsername);
          final sb =
              fuzzyScore(query, b.content) +
              0.5 * fuzzyScore(query, b.conversationName) +
              0.25 * fuzzyScore(query, b.senderUsername);
          return sb.compareTo(sa);
        });
        setState(() {
          _results = parsed;
          _loading = false;
        });
      } else {
        setState(() {
          _results = [];
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _results = [];
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = Responsive.isMobile(context);
    final width = isMobile ? MediaQuery.of(context).size.width - 32 : 560.0;

    return KeyboardListener(
      focusNode: _keyboardFocusNode,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
        }
      },
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Material(
          color: Colors.black54,
          child: Center(
            child: GestureDetector(
              onTap: () {}, // absorb taps on card
              child: Container(
                width: width,
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.7,
                ),
                margin: const EdgeInsets.symmetric(vertical: 48),
                decoration: BoxDecoration(
                  color: context.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Search input
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        onChanged: _onQueryChanged,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 15,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Search all messages...',
                          hintStyle: TextStyle(color: context.textMuted),
                          prefixIcon: Icon(
                            Icons.search,
                            color: context.textMuted,
                            size: 20,
                          ),
                          suffixIcon: _loading
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : null,
                          filled: true,
                          fillColor: context.mainBg,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                    // Results
                    if (_results.isNotEmpty)
                      Flexible(
                        child: ListView.builder(
                          itemCount: _results.length,
                          padding: const EdgeInsets.only(bottom: 8),
                          itemBuilder: (context, index) {
                            final r = _results[index];
                            return _buildResultTile(r);
                          },
                        ),
                      ),
                    if (_results.isEmpty &&
                        !_loading &&
                        _controller.text.trim().length >= 2)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No messages found',
                          style: TextStyle(
                            color: context.textMuted,
                            fontSize: 14,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResultTile(_SearchResult r) {
    // Truncate content for display
    final preview = r.content.length > 120
        ? '${r.content.substring(0, 120)}...'
        : r.content;

    String timeLabel = '';
    final dt = DateTime.tryParse(r.timestamp);
    if (dt != null) {
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inDays > 0) {
        timeLabel = '${diff.inDays}d ago';
      } else if (diff.inHours > 0) {
        timeLabel = '${diff.inHours}h ago';
      } else if (diff.inMinutes > 0) {
        timeLabel = '${diff.inMinutes}m ago';
      } else {
        timeLabel = 'just now';
      }
    }

    return Semantics(
      label: 'search result by ${r.senderUsername}',
      button: true,
      child: InkWell(
        onTap: () {
          Navigator.of(context).pop();
          widget.onResultTap(r.conversationId, r.messageId);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    r.senderUsername,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'in ${r.conversationName}',
                    style: TextStyle(color: context.textMuted, fontSize: 12),
                  ),
                  const Spacer(),
                  Text(
                    timeLabel,
                    style: TextStyle(color: context.textMuted, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                preview,
                style: TextStyle(color: context.textSecondary, fontSize: 13),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchResult {
  final String messageId;
  final String conversationId;
  final String conversationName;
  final String senderUsername;
  final String content;
  final String timestamp;

  _SearchResult({
    required this.messageId,
    required this.conversationId,
    required this.conversationName,
    required this.senderUsername,
    required this.content,
    required this.timestamp,
  });
}
