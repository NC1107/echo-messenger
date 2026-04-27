import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

/// All-caps muted label that introduces a card group in sectioned lists.
/// Pairs with [CardRow] groups in the Settings redesign.
class SectionHeader extends StatelessWidget {
  /// Plain label text. Rendered uppercase.
  final String label;

  const SectionHeader(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        16,
        EchoSectionTokens.headerTopGap,
        16,
        8,
      ),
      child: Text(
        label.toUpperCase(),
        style: EchoSectionTokens.sectionLabelStyle(context),
      ),
    );
  }
}
