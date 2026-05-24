import 'package:flutter/material.dart';

/// Shared layout shell for Settings sub-panels.
///
/// All Settings sub-panels share the same outer layout: a scrollable that
/// fills the right pane with the visible content centered and capped at
/// `maxWidth` pixels. The non-obvious bit is the wrap order — the scrollable
/// must be the *outer* widget, not the inner one. If the layout were
/// `Center > ConstrainedBox > ListView` (the old shape, fixed in #1157 and
/// extracted here in #1169), wheel events outside the content column would
/// fall through to no scroll surface and the user could only scroll while
/// hovering directly over a widget.
class SettingsPanelScaffold extends StatelessWidget {
  const SettingsPanelScaffold({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.all(24),
    this.maxWidth = 900,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: padding,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}
