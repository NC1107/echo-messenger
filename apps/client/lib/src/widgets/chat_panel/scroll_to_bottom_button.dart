// Floating "scroll to latest messages" FAB shown when the user has scrolled
// far enough up that new/recent messages are out of view.
import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

/// Threshold in pixels beyond which the button appears. One-and-a-half
/// typical viewport heights keeps it hidden for minor scroll-backs but
/// surfaces it whenever the user navigates significantly up the history.
const double kScrollToBottomThreshold = 900.0;

/// A small circular floating button that animates in when the user has
/// scrolled [kScrollToBottomThreshold] pixels above the bottom of the list.
///
/// Tapping it calls [onTap], which should invoke the panel's existing
/// scroll-to-bottom helper. The button hides automatically via [visible];
/// the caller drives visibility from the scroll listener.
class ScrollToBottomButton extends StatefulWidget {
  final bool visible;
  final VoidCallback onTap;

  const ScrollToBottomButton({
    super.key,
    required this.visible,
    required this.onTap,
  });

  @override
  State<ScrollToBottomButton> createState() => _ScrollToBottomButtonState();
}

class _ScrollToBottomButtonState extends State<ScrollToBottomButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOut,
  );
  late final Animation<double> _scale = Tween<double>(
    begin: 0.7,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));

  @override
  void initState() {
    super.initState();
    // If the button is initially visible (e.g. restored scroll state), skip
    // the entrance animation and jump straight to fully visible.
    if (widget.visible) {
      _ctrl.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant ScrollToBottomButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) {
      if (widget.visible) {
        _ctrl.forward();
      } else {
        _ctrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      // Sit above the new-messages pill position when both are shown; the pill
      // occupies bottom: EchoSpacing.md (≈12) so we use bottom: 56 here.
      bottom: 56,
      right: EchoSpacing.xl,
      child: FadeTransition(
        opacity: _fade,
        child: ScaleTransition(
          scale: _scale,
          child: Semantics(
            label: 'Jump to latest messages',
            button: true,
            child: GestureDetector(
              onTap: widget.onTap,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: context.surface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: context.accent.withValues(alpha: 0.35),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 22,
                  color: context.accent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
