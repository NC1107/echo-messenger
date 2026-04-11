import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../providers/conversations_provider.dart';
import '../theme/echo_theme.dart';

/// A Ctrl+K quick-switcher overlay for searching conversations, contacts,
/// and groups. Shows as a centered floating card with a search input.
class QuickSwitcherOverlay extends ConsumerStatefulWidget {
  final void Function(Conversation conversation) onSelect;

  const QuickSwitcherOverlay({super.key, required this.onSelect});

  @override
  ConsumerState<QuickSwitcherOverlay> createState() =>
      _QuickSwitcherOverlayState();
}

class _QuickSwitcherOverlayState extends ConsumerState<QuickSwitcherOverlay> {
  final _controller = TextEditingController();
  final _listScrollController = ScrollController();
  String _query = '';
  int _selectedIndex = 0;

  @override
  void dispose() {
    _controller.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  List<Conversation> _filteredResults() {
    final conversations = ref.read(conversationsProvider).conversations;
    if (_query.isEmpty) return conversations.take(8).toList();

    final q = _query.toLowerCase();
    return conversations.where((c) {
      final title = (c.name ?? '').toLowerCase();
      final members = c.members.map((m) => m.username.toLowerCase()).join(' ');
      return title.contains(q) || members.contains(q);
    }).toList();
  }

  void _selectCurrent(List<Conversation> results) {
    if (results.isNotEmpty && _selectedIndex < results.length) {
      widget.onSelect(results[_selectedIndex]);
      Navigator.of(context).pop();
    }
  }

  static const _itemHeight = 44.0;

  void _scrollToSelected() {
    if (!_listScrollController.hasClients) return;
    final offset = (_selectedIndex * _itemHeight).clamp(
      0.0,
      _listScrollController.position.maxScrollExtent,
    );
    _listScrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
    );
  }

  /// Handle keyboard navigation (arrows + escape) in the switcher.
  void _handleKeyNavigation(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final results = _filteredResults();
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _selectedIndex = (_selectedIndex + 1).clamp(0, results.length - 1);
      });
      _scrollToSelected();
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _selectedIndex = (_selectedIndex - 1).clamp(0, results.length - 1);
      });
      _scrollToSelected();
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
    }
  }

  /// Build a single result row in the conversation list.
  Widget _buildResultItem(Conversation conv, bool isSelected) {
    final title = conv.name ?? conv.id;
    return Container(
      height: _itemHeight,
      decoration: isSelected
          ? BoxDecoration(
              border: Border(left: BorderSide(color: context.accent, width: 2)),
            )
          : null,
      child: Material(
        color: isSelected
            ? context.accent.withValues(alpha: 0.1)
            : Colors.transparent,
        child: InkWell(
          onTap: () {
            widget.onSelect(conv);
            Navigator.of(context).pop();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(
                  conv.isGroup ? Icons.group : Icons.person,
                  size: 20,
                  color: context.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (conv.isGroup)
                  Text(
                    'Group',
                    style: TextStyle(color: context.textMuted, fontSize: 11),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = _filteredResults();

    return KeyboardListener(
      focusNode: FocusNode(),
      autofocus: true,
      onKeyEvent: _handleKeyNavigation,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Material(
          color: Colors.black54,
          child: Center(
            child: GestureDetector(
              onTap: () {}, // prevent backdrop tap
              child: Container(
                width: 500,
                constraints: const BoxConstraints(maxHeight: 400),
                decoration: BoxDecoration(
                  color: context.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 24,
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
                        autofocus: true,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 16,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Search conversations...',
                          hintStyle: TextStyle(color: context.textMuted),
                          prefixIcon: Icon(
                            Icons.search,
                            color: context.textMuted,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: context.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: context.accent),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                        onChanged: (value) {
                          setState(() {
                            _query = value;
                            _selectedIndex = 0;
                          });
                        },
                        onSubmitted: (_) => _selectCurrent(results),
                      ),
                    ),
                    if (results.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No results',
                          style: TextStyle(
                            color: context.textMuted,
                            fontSize: 14,
                          ),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.builder(
                          controller: _listScrollController,
                          itemCount: results.length,
                          itemBuilder: (context, index) => _buildResultItem(
                            results[index],
                            index == _selectedIndex,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Text(
                        'Enter to select \u2022 Esc to close',
                        style: TextStyle(
                          color: context.textMuted,
                          fontSize: 11,
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
}
