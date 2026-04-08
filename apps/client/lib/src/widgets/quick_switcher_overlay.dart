import 'package:flutter/material.dart';
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
  String _query = '';
  int _selectedIndex = 0;

  @override
  void dispose() {
    _controller.dispose();
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

  @override
  Widget build(BuildContext context) {
    final results = _filteredResults();

    return KeyboardListener(
      focusNode: FocusNode(),
      autofocus: true,
      onKeyEvent: (event) {
        // Arrow up/down to navigate, Enter to select, Escape to close
      },
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
                    // Search input
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
                    // Results list
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
                          shrinkWrap: true,
                          itemCount: results.length,
                          itemBuilder: (context, index) {
                            final conv = results[index];
                            final isSelected = index == _selectedIndex;
                            final title = conv.name ?? conv.id;
                            return Material(
                              color: isSelected
                                  ? context.accent.withValues(alpha: 0.1)
                                  : Colors.transparent,
                              child: InkWell(
                                onTap: () {
                                  widget.onSelect(conv);
                                  Navigator.of(context).pop();
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        conv.isGroup
                                            ? Icons.group
                                            : Icons.person,
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
                                          style: TextStyle(
                                            color: context.textMuted,
                                            fontSize: 11,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    // Hint
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
