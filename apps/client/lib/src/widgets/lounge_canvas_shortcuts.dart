import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/canvas_models.dart';

/// Keyboard shortcuts for the voice-lounge canvas.
///
/// Per [docs/voice-lounge/02-input-matrix.md] conflict rule 5:
/// shortcuts require the canvas [Focus] node to be active. Single-letter
/// keys (`B`, `E`, `T`, `Escape`) must not fire while the chat input
/// or any other text field has focus.
///
/// Wrap the canvas/InteractiveViewer with this widget and call
/// [FocusNode.requestFocus] when the user taps the canvas surface.
/// The [FocusNode] is created externally so the parent can both
/// track focus state and hand it to this widget.
///
/// Shortcuts exposed:
///   B → brush / pen tool
///   E → eraser tool
///   T → text tool
///   Escape → CanvasTool.none (exit drawing mode)
class LoungeCanvasShortcuts extends StatelessWidget {
  final Widget child;
  final FocusNode focusNode;
  final void Function(CanvasTool tool) onToolSelected;

  const LoungeCanvasShortcuts({
    super.key,
    required this.child,
    required this.focusNode,
    required this.onToolSelected,
  });

  @override
  Widget build(BuildContext context) {
    // CallbackShortcuts must be an ancestor of the Focus node so that key
    // events from canvasFocus travel upward through the widget tree and are
    // intercepted by CallbackShortcuts before reaching the root.
    //
    // Key event routing in Flutter: a key event is delivered to the primary
    // focus node and propagates UP through its ancestors (focus tree) until
    // consumed. CallbackShortcuts processes events that pass through its
    // subtree, so it must sit above the Focus node.
    //
    // The hasPrimaryFocus guard ensures that if a sibling branch (e.g. the
    // chat TextField) holds primary focus, its events travel up a DIFFERENT
    // ancestor path (not through this CallbackShortcuts) and the guard is a
    // belt-and-suspenders safety valve.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyB): () =>
            _dispatchIfFocused(CanvasTool.pen),
        const SingleActivator(LogicalKeyboardKey.keyE): () =>
            _dispatchIfFocused(CanvasTool.eraser),
        const SingleActivator(LogicalKeyboardKey.keyT): () =>
            _dispatchIfFocused(CanvasTool.text),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            _dispatchIfFocused(CanvasTool.none),
      },
      child: Focus(focusNode: focusNode, child: child),
    );
  }

  void _dispatchIfFocused(CanvasTool tool) {
    // Only fire when the canvas focus node itself is the primary focus.
    // If the chat input or any sibling text field is primary, this is a
    // no-op -- the key event reached us only because the focus scope
    // walked up to the root without finding a consumer.
    if (focusNode.hasPrimaryFocus) {
      onToolSelected(tool);
    }
  }
}
