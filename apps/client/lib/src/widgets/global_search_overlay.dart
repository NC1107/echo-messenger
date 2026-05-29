import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';
import '../utils/fuzzy_score.dart';
import 'avatar_utils.dart' show buildAvatar, groupAvatarColor, resolveAvatarUrl;
import 'echo_bottom_sheet.dart';
import 'user_avatar.dart';

/// Universal search overlay (Ctrl+Shift+F or search icon).
///
/// Searches messages (full-text, non-encrypted), contacts (by
/// username/display name), and groups (by title) in a single request.
/// Results are grouped by category with click-through navigation.
///
/// Additionally fetches `/api/groups/public?search=<q>` in parallel and
/// surfaces a "Discoverable groups" section for public groups the user has not
/// yet joined. Tapping a discoverable group opens an inline preview sheet with
/// a Join CTA, then reloads conversations on success.
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
  final _listScrollController = ScrollController();
  Timer? _debounce;
  _UniversalResults? _results;
  bool _loading = false;
  String _lastQuery = '';

  /// IDs of public groups currently mid-join (spinner state).
  final Set<String> _joiningIds = {};

  /// Selected index across the flattened activator list. Held as a
  /// [ValueNotifier] so arrow-key updates only repaint the previously
  /// selected and newly selected row instead of every visible tile.
  final ValueNotifier<int> _selectedIndex = ValueNotifier<int>(0);

  /// Per-result GlobalKeys so [Scrollable.ensureVisible] can resolve the
  /// real (variable-height) bounds of the currently selected row.
  /// Regenerated whenever the result set is replaced.
  List<GlobalKey> _rowKeys = const <GlobalKey>[];

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _listScrollController.dispose();
    _selectedIndex.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  /// Flatten all result categories into a single linear list for keyboard
  /// navigation. Each entry knows how to open itself when activated.
  List<VoidCallback> _flatResultActivators() {
    final r = _results;
    if (r == null) return const <VoidCallback>[];
    return <VoidCallback>[
      for (final m in r.messages)
        () {
          Navigator.of(context).pop();
          widget.onResultTap(m.conversationId, m.messageId);
        },
      for (final c in r.contacts)
        () {
          Navigator.of(context).pop();
          widget.onContactTap(c.userId, c.username);
        },
      for (final g in r.groups)
        () {
          Navigator.of(context).pop();
          widget.onResultTap(g.conversationId, '');
        },
      for (final pg in r.publicGroups) () => _showPublicGroupPreview(pg),
    ];
  }

  int get _totalResultCount {
    final r = _results;
    if (r == null) return 0;
    return r.messages.length +
        r.contacts.length +
        r.groups.length +
        r.publicGroups.length;
  }

  /// Scroll the selected row into view. Uses the row's GlobalKey instead of
  /// a fixed average row height so mixed-height tiles and section headers
  /// don't drift the math.
  void _scrollToSelected() {
    final i = _selectedIndex.value;
    if (i < 0 || i >= _rowKeys.length) return;
    final ctx = _rowKeys[i].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
      alignment: 0.5,
    );
  }

  KeyEventResult _handleKeyNavigation(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    final total = _totalResultCount;
    if (total == 0) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _selectedIndex.value = (_selectedIndex.value + 1).clamp(0, total - 1);
      _scrollToSelected();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _selectedIndex.value = (_selectedIndex.value - 1).clamp(0, total - 1);
      _scrollToSelected();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      // Resolve the activator at Enter-time from the current result list so
      // we never fire a stale closure captured before results changed.
      final activators = _flatResultActivators();
      final idx = _selectedIndex.value;
      if (idx >= 0 && idx < activators.length) {
        activators[idx]();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 2) {
      setState(() {
        _results = null;
        _loading = false;
        _rowKeys = const <GlobalKey>[];
      });
      _selectedIndex.value = 0;
      return;
    }
    setState(() {
      _loading = true;
    });
    _selectedIndex.value = 0;
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _search(query.trim());
    });
  }

  void _applyResults(_UniversalResults results) {
    final total =
        results.messages.length +
        results.contacts.length +
        results.groups.length +
        results.publicGroups.length;
    setState(() {
      _results = results;
      _loading = false;
      _rowKeys = List<GlobalKey>.generate(total, (_) => GlobalKey());
    });
    // Clamp after results changed: e.g. shrink 20→3 must not leave a stale
    // index that no longer maps to any row.
    _selectedIndex.value = _selectedIndex.value.clamp(
      0,
      math.max(0, total - 1),
    );
  }

  Future<void> _search(String query) async {
    if (query == _lastQuery) return;
    _lastQuery = query;

    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token ?? '';
    final headers = {'Authorization': 'Bearer $token'};

    final searchUri = Uri.parse(
      '$serverUrl/api/search?q=${Uri.encodeQueryComponent(query)}&limit=15',
    );
    final publicUri = Uri.parse(
      '$serverUrl/api/groups/public',
    ).replace(queryParameters: {'search': query, 'limit': '8', 'offset': '0'});

    try {
      // Fire both requests in parallel.
      final responses = await Future.wait([
        http.get(searchUri, headers: headers),
        http.get(publicUri, headers: headers),
      ]);
      if (!mounted) return;

      final searchResp = responses[0];
      final publicResp = responses[1];

      if (searchResp.statusCode != 200) {
        _applyResults(_UniversalResults.empty());
        return;
      }

      final body = jsonDecode(searchResp.body) as Map<String, dynamic>;
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

      // Build set of conversation IDs the user is already in so we can
      // de-duplicate against the discoverable results.
      final joinedIds = {
        for (final g in groups) g.conversationId,
        for (final c in conversations) c.id,
      };

      final publicGroups = _parsePublicGroups(publicResp, joinedIds);

      _applyResults(
        _UniversalResults(
          messages: messages,
          contacts: contacts,
          groups: groups,
          publicGroups: publicGroups,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      _applyResults(_UniversalResults.empty());
    }
  }

  /// Parses the `/api/groups/public` response and filters to groups where
  /// `is_member == false` and the group id is not already in [joinedIds].
  List<_PublicGroupResult> _parsePublicGroups(
    http.Response resp,
    Set<String> joinedIds,
  ) {
    if (resp.statusCode != 200) return const [];
    try {
      final decoded = jsonDecode(resp.body);
      final List<dynamic> raw = decoded is List
          ? decoded
          : (decoded as Map<String, dynamic>)['groups'] as List? ?? [];
      final results = <_PublicGroupResult>[];
      for (final item in raw) {
        final e = item as Map<String, dynamic>;
        final isMember = e['is_member'] as bool? ?? false;
        if (isMember) continue;
        final id = (e['id'] ?? e['conversation_id'] ?? '').toString();
        if (id.isEmpty || joinedIds.contains(id)) continue;
        results.add(
          _PublicGroupResult(
            id: id,
            title: (e['title'] ?? e['name'] ?? 'Unnamed').toString(),
            description: (e['description'] ?? e['desc']) as String?,
            iconUrl: (e['icon_url'] ?? e['avatar_url']) as String?,
            memberCount: (e['member_count'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      return results;
    } catch (_) {
      return const [];
    }
  }

  /// Shows an inline preview bottom sheet for a discoverable public group,
  /// matching the UX from [DiscoverGroupsScreen]. Handles the join POST itself
  /// so the overlay stays open while the sheet is up.
  void _showPublicGroupPreview(_PublicGroupResult group) {
    showEchoBottomSheet<void>(
      context,
      dragHandle: true,
      builder: (sheetCtx) {
        return _PublicGroupPreviewSheet(
          group: group,
          joiningIds: _joiningIds,
          onJoin: () => _joinPublicGroup(group),
        );
      },
    );
  }

  Future<void> _joinPublicGroup(_PublicGroupResult group) async {
    if (_joiningIds.contains(group.id)) return;
    setState(() => _joiningIds.add(group.id));

    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token ?? '';
    try {
      final resp = await http
          .post(
            Uri.parse('$serverUrl/api/groups/${group.id}/join'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        // Remove from discoverable list and reload conversations.
        setState(() {
          _joiningIds.remove(group.id);
          final r = _results;
          if (r != null) {
            _applyResults(
              _UniversalResults(
                messages: r.messages,
                contacts: r.contacts,
                groups: r.groups,
                publicGroups: r.publicGroups
                    .where((pg) => pg.id != group.id)
                    .toList(),
              ),
            );
          }
        });
        ref.read(conversationsProvider.notifier).loadConversations();
      } else {
        setState(() => _joiningIds.remove(group.id));
        if (mounted) {
          ToastService.show(
            context,
            'Failed to join group (${resp.statusCode})',
            type: ToastType.error,
          );
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _joiningIds.remove(group.id));
        ToastService.show(
          context,
          'Failed to join group',
          type: ToastType.error,
        );
      }
    }
  }

  bool get _hasResults =>
      _results != null &&
      (_results!.messages.isNotEmpty ||
          _results!.contacts.isNotEmpty ||
          _results!.groups.isNotEmpty ||
          _results!.publicGroups.isNotEmpty);

  bool get _showEmpty =>
      _results != null &&
      !_loading &&
      !_hasResults &&
      _controller.text.trim().length >= 2;

  @override
  Widget build(BuildContext context) {
    final isMobile = Responsive.isMobile(context);
    final screenWidth = MediaQuery.of(context).size.width;
    // Responsive width: tablets (< 900) get screen-48, desktops get fixed 560
    final width = _resolveOverlayWidth(isMobile, screenWidth);

    // Non-focusable Focus: observes keys without stealing the first keystroke from the TextField.
    return Focus(
      canRequestFocus: false,
      descendantsAreFocusable: true,
      skipTraversal: true,
      onKeyEvent: _handleKeyNavigation,
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
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 44),
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
                    ),
                    if (_hasResults) Flexible(child: _buildResultsList()),
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

  double _resolveOverlayWidth(bool isMobile, double screenWidth) {
    if (isMobile) return screenWidth - 32;
    if (screenWidth < 900) return screenWidth - 48;
    return 560.0;
  }

  /// Build the flat row list (headers + tiles) and render it lazily via
  /// [ListView.builder] so off-screen rows aren't materialized.
  Widget _buildResultsList() {
    final items = _flattenRows();
    return ListView.builder(
      controller: _listScrollController,
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: items.length,
      itemBuilder: (context, index) => items[index],
    );
  }

  /// Assemble the rendered rows in the same order as
  /// [_flatResultActivators] so the selection index aligns with what
  /// the user sees and what Enter activates.
  List<Widget> _flattenRows() {
    final rows = <Widget>[];
    final r = _results;
    if (r == null) return rows;
    var globalIndex = 0;
    if (r.messages.isNotEmpty) {
      rows.add(_buildSectionHeader('Messages'));
      for (final m in r.messages) {
        rows.add(_buildSelectableRow(globalIndex, _buildMessageTile(m)));
        globalIndex++;
      }
    }
    if (r.contacts.isNotEmpty) {
      rows.add(_buildSectionHeader('Contacts'));
      for (final c in r.contacts) {
        rows.add(_buildSelectableRow(globalIndex, _buildContactTile(c)));
        globalIndex++;
      }
    }
    if (r.groups.isNotEmpty) {
      rows.add(_buildSectionHeader('Groups'));
      for (final g in r.groups) {
        rows.add(_buildSelectableRow(globalIndex, _buildGroupTile(g)));
        globalIndex++;
      }
    }
    if (r.publicGroups.isNotEmpty) {
      rows.add(_buildSectionHeader('Discoverable groups'));
      for (final pg in r.publicGroups) {
        rows.add(_buildSelectableRow(globalIndex, _buildPublicGroupTile(pg)));
        globalIndex++;
      }
    }
    return rows;
  }

  /// Wraps a result tile in a [ValueListenableBuilder] keyed on
  /// [_selectedIndex] so only the previously-selected and newly-selected
  /// tiles repaint when the user presses arrow keys.
  Widget _buildSelectableRow(int index, Widget child) {
    final key = (index < _rowKeys.length) ? _rowKeys[index] : null;
    return KeyedSubtree(
      key: key,
      child: ValueListenableBuilder<int>(
        valueListenable: _selectedIndex,
        builder: (context, selected, _) {
          final isSelected = selected == index;
          return Container(
            decoration: BoxDecoration(
              color: isSelected ? context.accent.withValues(alpha: 0.1) : null,
              border: Border(
                left: BorderSide(
                  color: isSelected ? context.accent : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: _SelectionSemantics(isSelected: isSelected, child: child),
          );
        },
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

    return _RowSemanticsLabel(
      label: 'message from ${r.senderUsername} in ${r.conversationName}',
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

    return _RowSemanticsLabel(
      label: 'contact $label',
      child: InkWell(
        onTap: () {
          Navigator.of(context).pop();
          widget.onContactTap(r.userId, r.username);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              UserAvatar(
                userId: r.userId,
                username: label,
                avatarUrl: r.avatarUrl,
                radius: 16,
                openProfileOnTap: false,
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
    return _RowSemanticsLabel(
      label: 'group ${r.title}',
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

  Widget _buildPublicGroupTile(_PublicGroupResult r) {
    final isJoining = _joiningIds.contains(r.id);
    final serverUrl = ref.read(serverUrlProvider);
    return _RowSemanticsLabel(
      label: 'discoverable group ${r.title} — tap to preview and join',
      child: InkWell(
        onTap: () => _showPublicGroupPreview(r),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              buildAvatar(
                imageUrl: resolveAvatarUrl(r.iconUrl, serverUrl),
                name: r.title,
                radius: 16,
                bgColor: groupAvatarColor(r.title),
                fallbackIcon: const Icon(
                  Icons.group,
                  size: 16,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            r.title,
                            style: TextStyle(
                              color: context.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(Icons.public, size: 12, color: context.textMuted),
                      ],
                    ),
                    Text(
                      '${r.memberCount} member${r.memberCount == 1 ? '' : 's'}',
                      style: TextStyle(color: context.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _JoinChip(
                isJoining: isJoining,
                onJoin: () => _joinPublicGroup(r),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Selection-aware semantics wrapper. Sits inside the [ValueListenableBuilder]
/// so the `selected` flag stays in sync with the keyboard cursor without
/// forcing the underlying tile widgets to rebuild.
class _SelectionSemantics extends StatelessWidget {
  final bool isSelected;
  final Widget child;
  const _SelectionSemantics({required this.isSelected, required this.child});

  @override
  Widget build(BuildContext context) {
    return Semantics(selected: isSelected, button: true, child: child);
  }
}

/// Adds a stable accessibility label to a row tile. Kept separate from the
/// selection semantics so we can rebuild the `selected` flag without
/// recomputing the label string.
class _RowSemanticsLabel extends StatelessWidget {
  final String label;
  final Widget child;
  const _RowSemanticsLabel({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Semantics(label: label, child: child);
  }
}

class _UniversalResults {
  final List<_MessageResult> messages;
  final List<_ContactResult> contacts;
  final List<_GroupResult> groups;
  final List<_PublicGroupResult> publicGroups;

  const _UniversalResults({
    required this.messages,
    required this.contacts,
    required this.groups,
    this.publicGroups = const [],
  });

  factory _UniversalResults.empty() => const _UniversalResults(
    messages: [],
    contacts: [],
    groups: [],
    publicGroups: [],
  );
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

class _PublicGroupResult {
  final String id;
  final String title;
  final String? description;
  final String? iconUrl;
  final int memberCount;

  const _PublicGroupResult({
    required this.id,
    required this.title,
    required this.description,
    required this.iconUrl,
    required this.memberCount,
  });
}

/// Inline Join chip shown on the right side of each discoverable group row.
/// Renders a compact FilledButton or a spinner while the join is in flight.
class _JoinChip extends StatelessWidget {
  final bool isJoining;
  final VoidCallback onJoin;

  const _JoinChip({required this.isJoining, required this.onJoin});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Join group',
      button: true,
      child: FilledButton(
        onPressed: isJoining ? null : onJoin,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: isJoining
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text(
                'Join',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
      ),
    );
  }
}

/// Bottom-sheet preview for a discoverable public group.
/// Mirrors the preview in [DiscoverGroupsScreen] so the UX is consistent.
/// Stateless — all mutation happens via [onJoin] in the parent state.
class _PublicGroupPreviewSheet extends ConsumerWidget {
  final _PublicGroupResult group;
  final Set<String> joiningIds;
  final VoidCallback onJoin;

  const _PublicGroupPreviewSheet({
    required this.group,
    required this.joiningIds,
    required this.onJoin,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverUrl = ref.read(serverUrlProvider);
    final isJoining = joiningIds.contains(group.id);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              buildAvatar(
                imageUrl: resolveAvatarUrl(group.iconUrl, serverUrl),
                name: group.title,
                radius: 28,
                bgColor: groupAvatarColor(group.title),
                fallbackIcon: const Icon(
                  Icons.group,
                  size: 28,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.title,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.public, size: 13, color: context.textMuted),
                        const SizedBox(width: 4),
                        Text(
                          'Public group',
                          style: TextStyle(
                            color: context.textMuted,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Icon(
                          Icons.people_outline,
                          size: 13,
                          color: context.textMuted,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${group.memberCount} '
                          'member${group.memberCount == 1 ? '' : 's'}',
                          style: TextStyle(
                            color: context.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (group.description != null && group.description!.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              'About',
              style: TextStyle(
                color: context.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              group.description!,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 14,
                height: 1.45,
              ),
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: Semantics(
              label: 'Join ${group.title}',
              button: true,
              child: FilledButton(
                onPressed: isJoining
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        onJoin();
                      },
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: isJoining
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Join group',
                        style: TextStyle(
                          fontSize: 14,
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
