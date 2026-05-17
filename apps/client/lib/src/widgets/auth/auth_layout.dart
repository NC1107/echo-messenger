import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/echo_theme.dart';
import '../echo_logo_icon.dart';

/// Two-column auth layout for desktop and a single-column flow for phones.
///
/// At widths >= 900 the form sits in a 440-wide card on the right with a
/// brand panel on the left showing the wordmark, tagline, and a short list
/// of product highlights. Below 900 we fall back to the historical centered
/// form (the [compactHeader] is rendered above [formColumn]).
///
/// Callers pass [compactHeader] separately so the existing narrow header
/// (logo + "Echo" + tagline) keeps its semantics on phones. The wide layout
/// reuses the same logo/wordmark inside its brand panel and a smaller inline
/// title above the form card so text-based e2e selectors still match.
class AuthLayout extends StatelessWidget {
  /// Short marketing line shown under the wordmark in the brand panel.
  /// Example: "Sign up. Talk privately." / "Welcome back."
  final String tagline;

  /// Inline title displayed above [formColumn] inside the wide-mode form
  /// card. Phones get the [compactHeader] instead, which usually already
  /// carries this string in a larger size.
  final String formTitle;

  /// Logo+wordmark+tagline block used in narrow mode (typically the screen's
  /// existing `_buildHeader()`).
  final Widget compactHeader;

  /// The actual `Form` subtree -- fields, buttons, error text, etc.
  final Widget formColumn;

  /// Vertical padding above the form in narrow mode (lets each screen keep
  /// its existing scroll padding without leaking the constant here).
  final EdgeInsets narrowPadding;

  const AuthLayout({
    super.key,
    required this.tagline,
    required this.formTitle,
    required this.compactHeader,
    required this.formColumn,
    this.narrowPadding = const EdgeInsets.fromLTRB(24, 24, 24, 56),
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 900;
        if (isWide) {
          return _buildWide(context);
        }
        return _buildNarrow(context);
      },
    );
  }

  Widget _buildNarrow(BuildContext context) {
    return SafeArea(
      child: Center(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // On narrow phones (e.g. iPhone SE at 375px) a fixed 400 max-width
            // plus 48px of side padding overflows. Clamp to available width.
            final effectiveMax = constraints.maxWidth < 448
                ? constraints.maxWidth
                : 400.0;
            return ConstrainedBox(
              constraints: BoxConstraints(maxWidth: effectiveMax),
              child: SingleChildScrollView(
                padding: narrowPadding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    compactHeader,
                    const SizedBox(height: 32),
                    formColumn,
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildWide(BuildContext context) {
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: _BrandPanel(tagline: tagline)),
                const SizedBox(width: 48),
                _FormCard(
                  title: formTitle,
                  child: SingleChildScrollView(child: formColumn),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandPanel extends StatelessWidget {
  final String tagline;

  const _BrandPanel({required this.tagline});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const EchoLogoIcon(size: 96),
        const SizedBox(height: 16),
        Text(
          'Echo',
          style: GoogleFonts.inter(
            fontSize: 56,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.0,
            color: context.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          tagline,
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w500,
            color: context.textSecondary,
          ),
        ),
        const SizedBox(height: 32),
        const _FeatureRow(
          icon: Icons.lock_outline,
          title: 'End-to-end encrypted',
          body: 'Signal Protocol with X3DH + Double Ratchet',
        ),
        const SizedBox(height: 16),
        const _FeatureRow(
          icon: Icons.devices_outlined,
          title: 'Every platform',
          body: 'Web, Linux, Windows, Android, iOS',
        ),
        const SizedBox(height: 16),
        const _FeatureRow(
          icon: Icons.dns_outlined,
          title: 'Self-hostable',
          body: 'Your server, your data',
        ),
      ],
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: context.accent.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 20, color: context.accent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                body,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: context.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FormCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _FormCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Clamp the card width so it doesn't collide with the brand panel at
        // ~800px-wide tablets. 40% of available width keeps it proportional.
        final cardWidth = constraints.maxWidth > 0
            ? constraints.maxWidth * 0.4 < 440
                  ? constraints.maxWidth * 0.4
                  : 440.0
            : 440.0;
        return SizedBox(
          width: cardWidth,
          child: Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: context.surface.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Theme.of(context).dividerColor,
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: context.shadowColor,
                  blurRadius: 24,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(height: 20),
                child,
              ],
            ),
          ),
        );
      },
    );
  }
}
