import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/accessibility_provider.dart';
import '../../providers/gif_playback_provider.dart';
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
        constraints: const BoxConstraints(maxWidth: 900),
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

            const SizedBox(height: 20),

            // ── Live Preview ─────────────────────────────────────────────
            // Reflects the font-scale and high-contrast settings below in
            // real time so users can see effects without leaving Settings.
            Text(
              'Preview',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            MediaQuery.withClampedTextScaling(
              minScaleFactor: state.fontScale,
              maxScaleFactor: state.fontScale,
              child: Container(
                decoration: BoxDecoration(
                  color: context.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: context.accent,
                          child: Text(
                            'SP',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Sam Patel',
                          style: TextStyle(
                            color: context.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: context.accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'ADMIN',
                            style: TextStyle(
                              color: context.accent,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: context.accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'End-to-end encrypted. Self-hosted. '
                        'Your messages stay yours.',
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 14,
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '7:38 PM',
                      style: TextStyle(color: context.textMuted, fontSize: 11),
                    ),
                  ],
                ),
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

            // ── GIF autoplay (#1137) ──────────────────────────────────────
            // Autoplay is a motion / vestibular / distraction concern; lives
            // here next to Reduce Motion. Font size moved to Appearance.
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.gif_outlined),
              title: Text(
                'Auto-play GIFs',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                'When off, GIFs show as static thumbnails with a play button.',
                style: TextStyle(color: context.textMuted, fontSize: 12),
              ),
              value: ref.watch(gifPlaybackProvider).autoplayEnabled,
              onChanged: (v) =>
                  ref.read(gifPlaybackProvider.notifier).setAutoplay(v),
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

            const SizedBox(height: 16),

            // ── Hide undecryptable messages (#668) ─────────────────────────
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.lock_outline),
              title: Text(
                'Hide undecryptable messages',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                'When on, messages that cannot be decrypted are hidden '
                'entirely instead of showing a lock icon.',
                style: TextStyle(color: context.textMuted, fontSize: 12),
              ),
              value: state.hideUndecryptable,
              onChanged: notifier.setHideUndecryptable,
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
