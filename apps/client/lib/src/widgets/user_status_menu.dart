import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../theme/echo_theme.dart';
import '../utils/presence.dart';
import 'loading_indicator.dart';

/// Maximum characters for custom status text (server cap is 64).
const int kStatusMaxLength = 80;

/// Presence options surfaced in the user status menu.
const _kPresenceOptions = <({String value, String label})>[
  (value: 'online', label: 'Online'),
  (value: 'away', label: 'Idle'),
  (value: 'dnd', label: 'DND'),
  (value: 'invisible', label: 'Invisible'),
];

/// Bottom-sheet content for the user status menu.
///
/// Shows four presence radio rows + a custom-status row. Reads
/// [authProvider] directly so it can be placed in any [ProviderScope].
class UserStatusMenuSheet extends ConsumerWidget {
  const UserStatusMenuSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presence = ref.watch(authProvider.select((s) => s.presenceStatus));
    final statusText = ref.watch(authProvider.select((s) => s.statusText));

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final opt in _kPresenceOptions)
            _PresenceRow(
              label: opt.label,
              color: presenceColor(opt.value),
              selected: presence == opt.value,
              onTap: () {
                ref.read(authProvider.notifier).setPresenceStatus(opt.value);
                Navigator.of(context).pop();
              },
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Divider(height: 1, color: context.border),
          ),
          CustomStatusRow(
            currentStatus: statusText,
            onSave: (text) => ref
                .read(authProvider.notifier)
                .setStatusText(text.isEmpty ? null : text),
            onClear: () => ref.read(authProvider.notifier).setStatusText(null),
          ),
        ],
      ),
    );
  }
}

/// A single presence radio row inside the status menu.
class _PresenceRow extends StatelessWidget {
  const _PresenceRow({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'set status $label',
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: context.textPrimary, fontSize: 14),
                ),
              ),
              if (selected) Icon(Icons.check, size: 16, color: context.accent),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline custom-status row.
///
/// - When [currentStatus] is null/empty: shows a text field with
///   "Set a custom status..." hint + a check icon to save.
/// - When [currentStatus] is set: shows the status text + an X icon
///   button to clear inline.
class CustomStatusRow extends StatefulWidget {
  const CustomStatusRow({
    super.key,
    required this.currentStatus,
    required this.onSave,
    required this.onClear,
  });

  final String? currentStatus;
  final Future<void> Function(String text) onSave;
  final Future<void> Function() onClear;

  @override
  State<CustomStatusRow> createState() => _CustomStatusRowState();
}

class _CustomStatusRowState extends State<CustomStatusRow> {
  late final TextEditingController _ctrl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.currentStatus ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool get _hasStatus {
    final s = widget.currentStatus;
    return s != null && s.isNotEmpty;
  }

  Future<void> _save() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.onSave(text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onClear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: _hasStatus ? _buildClearRow(context) : _buildInputRow(context),
    );
  }

  Widget _buildClearRow(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.chat_bubble_outline, size: 18, color: context.textSecondary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            widget.currentStatus!,
            style: TextStyle(color: context.textPrimary, fontSize: 14),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Semantics(
          label: 'clear custom status',
          button: true,
          child: SizedBox(
            width: 32,
            height: 32,
            child: _busy
                ? const Center(child: InlineLoadingSpinner(size: 14))
                : IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(
                      Icons.close,
                      size: 16,
                      color: context.textSecondary,
                    ),
                    onPressed: _clear,
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildInputRow(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.chat_bubble_outline, size: 18, color: context.textSecondary),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: _ctrl,
            maxLength: kStatusMaxLength,
            maxLines: 1,
            style: TextStyle(color: context.textPrimary, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Set a custom status...',
              hintStyle: TextStyle(color: context.textMuted, fontSize: 14),
              isDense: true,
              counterText: '',
              border: InputBorder.none,
            ),
            onSubmitted: (_) => _save(),
          ),
        ),
        Semantics(
          label: 'save custom status',
          button: true,
          child: SizedBox(
            width: 32,
            height: 32,
            child: _busy
                ? const Center(child: InlineLoadingSpinner(size: 14))
                : IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(Icons.check, size: 16, color: context.accent),
                    onPressed: _save,
                  ),
          ),
        ),
      ],
    );
  }
}
