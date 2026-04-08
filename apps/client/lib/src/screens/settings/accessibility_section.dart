import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/echo_theme.dart';

const _kFontScale = 'accessibility_font_scale';
const _kReducedMotion = 'accessibility_reduced_motion';
const _kHighContrast = 'accessibility_high_contrast';

class AccessibilitySection extends StatefulWidget {
  const AccessibilitySection({super.key});

  @override
  State<AccessibilitySection> createState() => _AccessibilitySectionState();
}

class _AccessibilitySectionState extends State<AccessibilitySection> {
  double _fontScale = 1.0;
  bool _reducedMotion = false;
  bool _highContrast = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _fontScale = prefs.getDouble(_kFontScale) ?? 1.0;
      _reducedMotion = prefs.getBool(_kReducedMotion) ?? false;
      _highContrast = prefs.getBool(_kHighContrast) ?? false;
    });
  }

  Future<void> _setFontScale(double value) async {
    setState(() => _fontScale = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kFontScale, value);
  }

  Future<void> _setReducedMotion(bool value) async {
    setState(() => _reducedMotion = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kReducedMotion, value);
  }

  Future<void> _setHighContrast(bool value) async {
    setState(() => _highContrast = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHighContrast, value);
  }

  @override
  Widget build(BuildContext context) {
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
              child: Slider(
                value: _fontScale,
                min: 0.8,
                max: 1.5,
                divisions: 7,
                label: '${(_fontScale * 100).round()}%',
                onChanged: _setFontScale,
              ),
            ),
            Text(
              '150%',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
          ],
        ),
        Text(
          'Current: ${(_fontScale * 100).round()}%',
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
          value: _reducedMotion,
          onChanged: _setReducedMotion,
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
          value: _highContrast,
          onChanged: _setHighContrast,
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
              fontSize: 14 * _fontScale,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}
