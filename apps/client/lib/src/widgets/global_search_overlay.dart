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

/// Universal search overlay (Ctrl+Shift+F or search icon).
///
/// Searches messages (full-text, non-encrypted), contacts (by
/// username/display name), and groups (by title) in a single request.
/// Results are grouped by category with click-through navigation.
class GlobalSearchOverlay extends ConsumerStatefulWidget {
  final void Function(String conversationId, String messageId) onResultTap;
  final void Function(String userId, String username) onContactTap;

  const GlobalSearchOverlay({
    super.key,
    required this.onResultTap,
    required this.onContactTap,
  });

  @override
  ConsumerState<GlobalSearchOverlay> createState() =>
      _GlobalSearchOverlayState();
}

class _GlobalSearchOverlayState extends ConsumerState<GlobalSearchOverlay> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _keyboardFocusNode = FocusNode();
  Timer? _debounce;
  _UniversalResults? _results;
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
        _results = null;
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
      '$serverUrl/api/search?q=${Uri.encodeQueryComponent(query)}&limit=15',
    );

    try {
      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final conversations = ref.read(conversationsProvider).conversations;
        final myUserId = ref.read(authProvider).userId ?? '';

        final rawMessages = (body['messages'] as List? ?? []);
        final messages = rawMessages.map((item) {
          final e = item as Map<String, dynamic>;
          final convId = (e['conversation_id'] ?? '').toString();
          final conv = conversations.where((c) => c.id == convId).firstOrNull;
          return _MessageResult(
            messageId: (e['message_id'] ?? '').toString(),
            conversationId: convId,
            conversationName: conv?.displayName(myUserId) ?? 'Unknown',
            senderUsername: (e['sender_username'] ?? '').toString(),
            content: (e['content'] ?? '').toString(),
            timestamp: (e['created_at'] ?? '').toString(),
          );
        }).toList();
        messages.sort((a, b) {
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

        final rawContacts = (body['contacts'] as List? ?? []);
        final contacts = rawContacts.map((item) {
          final e = item as Map<String, dynamic>;
          return _ContactResult(
            userId: (e['user_id'] ?? '').toString(),
            username: (e['username'] ?? '').toString(),
            displayName: e['display_name'] as String?,
            avatarUrl: e['avatar_url'] as String?,
          );
        }).toList();

        final rawGroups = (body['groups'] as List? ?? []);
        final groups = rawGroups.map((item) {
          final e = item as Map<String, dynamic>;
          return _GroupResult(
            conversationId: (e['conversation_id'] ?? '').toString(),
            title: (e['title'] ?? 'Unnamed Group').toString(),
            description: e['description'] as String?,
            memberCount: (e['member_count'] as num?)?.toInt() ?? 0,
          );
        }).toList();

        setState(() {
          _results = _UniversalResults(
            messages: messages,
            contacts: contacts,
            groups: groups,
          );
          _loading = false;
        });
      } else {
        setState(() {
          _results = _UniversalResults.empty();
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _results = _UniversalResults.empty();
        _loading = false;
      });
    }
  }

  bool get _hasResults =>
      _results != null &&
      (_results!.messages.isNotEmpty ||
          _results!.contacts.isNotEmpty ||
          _results!.groups.isNotEmpty);

  bool get _showEmpty =>
      _results != null &&
      !_loading &&
      !_hasResults &&
      _controller.text.trim().length >= 2;

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
              onTap: () {},
              child: Container(
                width: width,
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.75,
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
                          hintText: 'Search messages, contacts, groups...',
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
                    if (_hasResults)
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.only(bottom: 12),
                          children: [
                            if (_results!.messages.isNotEmpty) ...[
                              _buildSectionHeader('Messages'),
                              ..._results!.messages.map(_buildMessageTile),
                            ],
                            if (_results!.contacts.isNotEmpty) ...[
                              _buildSectionHeader('Contacts'),
                              ..._results!.contacts.map(_buildContactTile),
                            ],
                            if (_results!.groups.isNotEmpty) ...[
                              _buildSectionHeader('Groups'),
                              ..._results!.groups.map(_buildGroupTile),
                            ],
                          ],
                        ),
                      ),
                    if (_showEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No results found',
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

  Widget _buildSectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Text(
        label,
        style: TextStyle(
          color: context.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildMessageTile(_MessageResult r) {
    final preview = r.content.length > 120
        ? '${r.content.substring(0, 120)}...'
        : r.content;

    String timeLabel = '';
    final dt = DateTime.tryParse(r.timestamp);
    if (dt != null) {
      final diff = DateTime.now().difference(dt);
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
      label: 'message from ${r.senderUsername} in ${r.conversationName}',
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
                  Expanded(
                    child: Text(
                      'in ${r.conversationName}',
                      style: TextStyle(color: context.textMuted, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
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

  Widget _buildContactTile(_ContactResult r) {
    final label = (r.displayName != null && r.displayName!.isNotEmpty)
        ? r.displayName!
        : r.username;

    return Semantics(
      label: 'contact $label',
      button: true,
      child: InkWell(
        onTap: () {
          Navigator.of(context).pop();
          widget.onContactTap(r.userId, r.username);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: context.accent.withValues(alpha: 0.15),
                backgroundImage: r.avatarUrl != null
                    ? NetworkImage(r.avatarUrl!)
                    : null,
                child: r.avatarUrl == null
                    ? Text(
                        label.isNotEmpty ? label[0].toUpperCase() : '?',
                        style: TextStyle(
                          color: context.accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (r.displayName != null && r.displayName!.isNotEmpty)
                      Text(
                        '@${r.username}',
                        style: TextStyle(
                          color: context.textMuted,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              Icon(
                Icons.chat_bubble_outline,
                size: 16,
                color: context.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGroupTile(_GroupResult r) {
    return Semantics(
      label: 'group ${r.title}',
      button: true,
      child: InkWell(
        onTap: () {
          Navigator.of(context).pop();
          widget.onResultTap(r.conversationId, '');
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: context.accent.withValues(alpha: 0.15),
                child: Text(
                  r.title.isNotEmpty ? r.title[0].toUpperCase() : '#',
                  style: TextStyle(
                    color: context.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.title,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${r.memberCount} member${r.memberCount == 1 ? '' : 's'}',
                      style: TextStyle(color: context.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(Icons.group_outlined, size: 16, color: context.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _UniversalResults {
  final List<_MessageResult> messages;
  final List<_ContactResult> contacts;
  final List<_GroupResult> groups;

  const _UniversalResults({
    required this.messages,
    required this.contacts,
    required this.groups,
  });

  factory _UniversalResults.empty() =>
      const _UniversalResults(messages: [], contacts: [], groups: []);
}

class _MessageResult {
  final String messageId;
  final String conversationId;
  final String conversationName;
  final String senderUsername;
  final String content;
  final String timestamp;

  _MessageResult({
    required this.messageId,
    required this.conversationId,
    required this.conversationName,
    required this.senderUsername,
    required this.content,
    required this.timestamp,
  });
}

class _ContactResult {
  final String userId;
  final String username;
  final String? displayName;
  final String? avatarUrl;

  _ContactResult({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.avatarUrl,
  });
}

class _GroupResult {
  final String conversationId;
  final String title;
  final String? description;
  final int memberCount;

  _GroupResult({
    required this.conversationId,
    required this.title,
    required this.description,
    required this.memberCount,
  });
}
