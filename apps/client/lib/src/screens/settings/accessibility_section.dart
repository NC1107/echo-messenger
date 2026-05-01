import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/accessibility_provider.dart';
import '../../theme/echo_theme.dart';

/// Dedicated Accessibility settings section.
///
/// Exposes three controls backed by [accessibilityProvider]:
///  - Reduce Motion  (bool, default false, persists to [kAccessibilityReducedMotion])
///  - Font Scale     (double 0.85–1.5, default 1.0, persists to [kAccessibilityFontScale])
///  - High Contrast  (bool, default false, persists to [kAccessibilityHighContrast])
///
/// The [MediaQuery] overrides (textScaler + disableAnimations) and the
/// [MaterialApp] theme switch for high contrast are applied in app.dart —
/// these controls are the sole user-facing entry point for those settings.
class AccessibilitySection extends ConsumerWidget {
  const AccessibilitySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(accessibilityProvider);
    final notifier = ref.read(accessibilityProvider.notifier);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(
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
            const Divider(height: 32),

            // ── Reduce Motion ─────────────────────────────────────────────
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.animation_outlined),
              title: Text(
                'Reduce Motion',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                'Disable animated transitions and effects.',
                style: TextStyle(color: context.textMuted, fontSize: 12),
              ),
              value: state.reducedMotion,
              onChanged: notifier.setReducedMotion,
            ),

            const SizedBox(height: 8),

            // ── Font Scale ────────────────────────────────────────────────
            Text(
              'Font Size',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
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
                  '85%',
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                ),
                Expanded(
                  child: Semantics(
                    label: 'font size',
                    slider: true,
                    value: '${(state.fontScale * 100).round()}%',
                    child: Slider(
                      value: state.fontScale,
                      min: 0.85,
                      max: 1.5,
                      divisions: 13,
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

            const SizedBox(height: 16),

            // ── High Contrast ─────────────────────────────────────────────
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.contrast_outlined),
              title: Text(
                'High Contrast',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                'Increase contrast for better readability.',
                style: TextStyle(color: context.textMuted, fontSize: 12),
              ),
              value: state.highContrast,
              onChanged: notifier.setHighContrast,
            ),

            const SizedBox(height: 24),
            Text(
              'OS accessibility preferences (reduce motion, large text) are '
              'detected automatically and applied on first launch.',
              style: TextStyle(
                color: context.textMuted,
                fontSize: 11,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
