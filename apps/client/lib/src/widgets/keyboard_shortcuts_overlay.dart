import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/echo_theme.dart';

/// A keyboard shortcut reference overlay.
/// Opened with Ctrl+/ from the main home screen.
class KeyboardShortcutsOverlay extends StatefulWidget {
  const KeyboardShortcutsOverlay({super.key});

  @override
  State<KeyboardShortcutsOverlay> createState() =>
      _KeyboardShortcutsOverlayState();
}

class _KeyboardShortcutsOverlayState extends State<KeyboardShortcutsOverlay> {
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  static const _sections = <_ShortcutSection>[
    _ShortcutSection('Navigation', [
      _Shortcut('Ctrl+K', 'Quick-switch conversations'),
      _Shortcut('Ctrl+/', 'Show keyboard shortcuts'),
      _Shortcut('Esc', 'Close overlay / cancel action'),
    ]),
    _ShortcutSection('Messaging', [
      _Shortcut('Enter', 'Send message'),
      _Shortcut('Shift+Enter', 'New line in message'),
      _Shortcut('↑', 'Edit last sent message (when input is empty)'),
      _Shortcut('Ctrl+V', 'Paste text or image'),
    ]),
    _ShortcutSection('Messages', [
      _Shortcut('Long press', 'React to message (mobile)'),
      _Shortcut('Hover + ❤', 'React to message (desktop)'),
      _Shortcut('Swipe →', 'Reply to message (mobile)'),
      _Shortcut('Hover + ↩', 'Reply to message (desktop)'),
    ]),
    _ShortcutSection('Editing', [
      _Shortcut('Ctrl+C', 'Copy selected text'),
      _Shortcut('Ctrl+X', 'Cut selected text'),
      _Shortcut('Esc', 'Cancel message edit (while editing)'),
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Material(
          color: Colors.black.withValues(alpha: 0.6),
          child: Center(
            child: GestureDetector(
              onTap: () {}, // prevent backdrop tap
              child: Container(
                width: 520,
                constraints: const BoxConstraints(maxHeight: 520),
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
                    // Header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                      child: Row(
                        children: [
                          Icon(
                            Icons.keyboard_outlined,
                            size: 18,
                            color: context.accent,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Keyboard Shortcuts',
                              style: TextStyle(
                                color: context.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.close,
                              size: 18,
                              color: context.textMuted,
                            ),
                            onPressed: () => Navigator.of(context).pop(),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: context.border),
                    // Shortcut list
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final section in _sections) ...[
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 8,
                                  bottom: 6,
                                ),
                                child: Text(
                                  section.title,
                                  style: TextStyle(
                                    color: context.textMuted,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ),
                              for (final s in section.shortcuts)
                                _ShortcutRow(shortcut: s),
                              const SizedBox(height: 4),
                            ],
                          ],
                        ),
                      ),
                    ),
                    // Footer hint
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                      child: Text(
                        'Esc to close',
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

class _ShortcutSection {
  final String title;
  final List<_Shortcut> shortcuts;
  const _ShortcutSection(this.title, this.shortcuts);
}

class _Shortcut {
  final String keys;
  final String description;
  const _Shortcut(this.keys, this.description);
}

class _ShortcutRow extends StatelessWidget {
  final _Shortcut shortcut;

  const _ShortcutRow({required this.shortcut});

  @override
  Widget build(BuildContext context) {
    // Split compound shortcuts like "Ctrl+K" or "Shift+Enter" into parts.
    // Single tokens (like "↑", "Esc", "Long press") are shown as one chip.
    final parts = _splitKeys(shortcut.keys);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 210,
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (int i = 0; i < parts.length; i++) ...[
                  _KeyChip(parts[i]),
                  if (i < parts.length - 1)
                    Text(
                      '+',
                      style: TextStyle(color: context.textMuted, fontSize: 12),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              shortcut.description,
              style: TextStyle(color: context.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// Splits a shortcut string like "Ctrl+K" into ["Ctrl", "K"].
  /// Preserves multi-word tokens (e.g. "Long press" stays as one part).
  static List<String> _splitKeys(String keys) {
    // Use + as separator only when surrounded by identifier-like chars.
    // e.g. "Ctrl+K" → ["Ctrl", "K"], "Hover + ❤" → ["Hover ", " ❤"]
    // Simple heuristic: split on bare `+` (not surrounded by spaces).
    if (keys.contains('+') && !keys.contains(' + ')) {
      return keys.split('+');
    }
    return [keys];
  }
}

class _KeyChip extends StatelessWidget {
  final String label;
  const _KeyChip(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: context.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            offset: const Offset(0, 1),
            blurRadius: 2,
          ),
        ],
      ),
      child: Text(
        label,
        style: TextStyle(
          color: context.textPrimary,
          fontSize: 12,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
