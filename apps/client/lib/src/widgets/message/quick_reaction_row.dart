import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../theme/echo_theme.dart';
import '../message_item.dart' show reactionEmojis;

/// Horizontal quick-reaction picker shown inside the mobile action sheet.
///
/// Wraps the emoji row in a fade `ShaderMask` so the leading + trailing edges
/// hint at off-screen emojis. On desktop / web, where the fade is easy to
/// miss, a 16px chevron overlay is rendered when the row actually overflows
/// — tapping scrolls by ~80px (#577).
class QuickReactionRow extends StatefulWidget {
  final ChatMessage message;
  final String myUserId;
  final void Function(String emoji) onSelect;
  final VoidCallback onMore;

  const QuickReactionRow({
    super.key,
    required this.message,
    required this.myUserId,
    required this.onSelect,
    required this.onMore,
  });

  @override
  State<QuickReactionRow> createState() => _QuickReactionRowState();
}

class _QuickReactionRowState extends State<QuickReactionRow> {
  final ScrollController _controller = ScrollController();
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    // Recompute after first layout so initial chevron visibility is correct.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScroll();
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    final left = pos.pixels > 0;
    final right = pos.pixels < pos.maxScrollExtent;
    if (left != _canScrollLeft || right != _canScrollRight) {
      setState(() {
        _canScrollLeft = left;
        _canScrollRight = right;
      });
    }
  }

  void _nudge(int direction) {
    if (!_controller.hasClients) return;
    final target = (_controller.offset + 80 * direction).clamp(
      0.0,
      _controller.position.maxScrollExtent,
    );
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  /// Pointer devices (desktop / web). We hide chevrons on phones + tablets
  /// where the existing fade hint is enough and the chevron would clutter
  /// the touch picker.
  bool get _isPointerDevice {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final textDir = Directionality.of(context);
    final showChevrons = _isPointerDevice;

    return Stack(
      alignment: Alignment.center,
      children: [
        ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => const LinearGradient(
            begin: AlignmentDirectional.centerStart,
            end: AlignmentDirectional.centerEnd,
            stops: [0.0, 0.04, 0.96, 1.0],
            colors: [
              Colors.transparent,
              Colors.black,
              Colors.black,
              Colors.transparent,
            ],
          ).createShader(bounds, textDirection: textDir),
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                for (final emoji in reactionEmojis) ...[
                  Builder(
                    builder: (_) {
                      final alreadyReacted = widget.message.reactions.any(
                        (r) => r.emoji == emoji && r.userId == widget.myUserId,
                      );
                      return GestureDetector(
                        onTap: () => widget.onSelect(emoji),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: alreadyReacted
                                ? context.accent.withValues(alpha: 0.2)
                                : null,
                            borderRadius: BorderRadius.circular(8),
                            border: alreadyReacted
                                ? Border.all(color: context.accent, width: 2)
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            emoji,
                            style: const TextStyle(
                              fontSize: 24,
                              decoration: TextDecoration.none,
                              fontFamilyFallback: ['NotoEmoji'],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 4),
                ],
                Semantics(
                  button: true,
                  label: 'More emojis',
                  child: GestureDetector(
                    onTap: widget.onMore,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.add_reaction_outlined,
                        size: 24,
                        color: context.accent,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (showChevrons && _canScrollLeft)
          Positioned(
            left: 0,
            child: _ChevronButton(
              icon: Icons.chevron_left,
              label: 'Scroll reactions left',
              onTap: () => _nudge(-1),
            ),
          ),
        if (showChevrons && _canScrollRight)
          Positioned(
            right: 0,
            child: _ChevronButton(
              icon: Icons.chevron_right,
              label: 'Scroll reactions right',
              onTap: () => _nudge(1),
            ),
          ),
      ],
    );
  }
}

class _ChevronButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ChevronButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: context.surface.withValues(alpha: 0.9),
        shape: const CircleBorder(),
        elevation: 1,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 24,
            height: 24,
            child: Icon(icon, size: 16, color: context.textSecondary),
          ),
        ),
      ),
    );
  }
}
