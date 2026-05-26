import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/echo_theme.dart';

/// Prominent "we are in beta" callout shown on the login / register screens
/// so a brand-new user sees it before signing up. The earlier placement was
/// inside the onboarding wizard, which a returning login never sees, so
/// existing testers never got the warning either.
///
/// Visual treatment: accent-tinted card, flask icon, all-caps heading,
/// short body, and a tappable "Learn more" affordance. Subtle enough that
/// it doesn't look like an error, prominent enough that it doesn't get
/// scanned past.
class BetaBanner extends StatelessWidget {
  /// Optional URL opened by the "Learn more" link. When null, the link is
  /// hidden so the banner degrades to a static notice. Default points to
  /// the marketing site's beta page.
  final Uri? learnMoreUri;

  const BetaBanner({super.key, this.learnMoreUri});

  /// Default Learn-more URL for the production landing page. Pulled into a
  /// factory rather than a const so unit tests can stub it.
  factory BetaBanner.standard({Key? key}) {
    return BetaBanner(
      key: key,
      learnMoreUri: Uri.parse('https://echo-messenger.us/beta'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label:
          'Beta notice: Echo is in beta. Bugs and breakage are expected, and '
          'your data may be reset before the public release.',
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.accentLight,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.accent, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.science_outlined, size: 18, color: context.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Echo is in beta',
                    style: TextStyle(
                      color: context.accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Bugs and data resets are expected before public launch.',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            if (learnMoreUri != null)
              Semantics(
                button: true,
                label: 'learn more about beta',
                child: InkWell(
                  onTap: () => launchUrl(
                    learnMoreUri!,
                    mode: LaunchMode.externalApplication,
                  ),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                    child: Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: context.accent,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
