import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/accessibility_provider.dart';
import '../../theme/echo_theme.dart';

class AccessibilitySection extends ConsumerWidget {
  const AccessibilitySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(accessibilityProvider);
    final notifier = ref.read(accessibilityProvider.notifier);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Accessibility',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Adjust the app to your needs.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const Divider(height: 24),
        // Font size
        Text(
          'Font Size',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Scale text across the app. Default is 100%.',
          style: TextStyle(color: context.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              '80%',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            Expanded(
              child: Semantics(
                label: 'font size',
                slider: true,
                value: '${(state.fontScale * 100).round()}%',
                child: Slider(
                  value: state.fontScale,
                  min: 0.8,
                  max: 1.5,
                  divisions: 7,
                  label: '${(state.fontScale * 100).round()}%',
                  onChanged: notifier.setFontScale,
                ),
              ),
            ),
            Text(
              '150%',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
          ],
        ),
        Text(
          'Current: ${(state.fontScale * 100).round()}%',
          style: TextStyle(color: context.textSecondary, fontSize: 12),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        // Reduced motion
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Reduce Motion',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Disable animated transitions and effects.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: state.reducedMotion,
          onChanged: notifier.setReducedMotion,
        ),
        const SizedBox(height: 8),
        // High contrast
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'High Contrast',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Increase contrast for better readability.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: state.highContrast,
          onChanged: notifier.setHighContrast,
        ),
        const SizedBox(height: 24),
        // Preview
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.border),
          ),
          child: Text(
            'The quick brown fox jumps over the lazy dog.',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}
