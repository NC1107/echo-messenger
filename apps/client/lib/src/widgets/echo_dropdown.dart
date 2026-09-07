import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

/// A themed dropdown that unifies the app's previously hand-rolled
/// `DropdownButtonFormField` / `InputDecorator`+`DropdownButton` variants.
///
/// Every dropdown that used to roll its own border, contrast, item text style
/// and menu colour now shares this one source of truth — so they look and
/// behave identically. The resting border uses [EchoColors.textMuted] (not the
/// fainter divider colour) so the control no longer "blends into the
/// background".
class EchoDropdown<T> extends StatelessWidget {
  const EchoDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.labelText,
    this.hintText,
    this.icon,
    this.isExpanded = true,
    this.menuMaxHeight = 320,
  });

  /// Currently-selected value (passed to the field's `initialValue`).
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final String? labelText;
  final String? hintText;
  final Widget? icon;
  final bool isExpanded;
  final double? menuMaxHeight;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: isExpanded,
      menuMaxHeight: menuMaxHeight,
      dropdownColor: context.surface,
      style: TextStyle(color: context.textPrimary, fontSize: 14),
      icon: icon ?? const Icon(Icons.arrow_drop_down),
      decoration: InputDecoration(
        labelText: labelText,
        hintText: hintText,
        labelStyle: TextStyle(color: context.textSecondary),
        hintStyle: TextStyle(color: context.textMuted),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.textMuted),
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
      items: items,
      onChanged: onChanged,
    );
  }
}
