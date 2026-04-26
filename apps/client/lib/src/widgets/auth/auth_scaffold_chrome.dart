import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';
import '../../version.dart';

/// Subtle radial gradient that fills the otherwise-empty scaffold so the
/// auth forms (login, register) do not float in a flat black void.
class AuthBackground extends StatelessWidget {
  const AuthBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.4,
            colors: [context.accent.withValues(alpha: 0.06), context.mainBg],
            stops: const [0.0, 0.6],
          ),
        ),
      ),
    );
  }
}

/// Version footer shown below auth forms. In release builds this is a single
/// "Echo vX.Y.Z" line. In debug builds it also shows server reachability and
/// (on web) the deployed web bundle version, so testers can confirm which
/// backend they're hitting.
class AuthVersionFooter extends StatelessWidget {
  final Future<Map<String, String?>>? versionFuture;

  const AuthVersionFooter({super.key, required this.versionFuture});

  @override
  Widget build(BuildContext context) {
    final appLine = Text(
      'Echo v$appVersion',
      textAlign: TextAlign.center,
      style: TextStyle(color: context.textMuted, fontSize: 11),
    );
    if (!kDebugMode) return appLine;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        appLine,
        FutureBuilder<Map<String, String?>>(
          future: versionFuture,
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const SizedBox.shrink();
            return _ServerVersionDetails(info: snapshot.data!);
          },
        ),
      ],
    );
  }
}

class _ServerVersionDetails extends StatelessWidget {
  final Map<String, String?> info;

  const _ServerVersionDetails({required this.info});

  @override
  Widget build(BuildContext context) {
    final serverVersion = info['serverVersion'];
    final serverHost = info['serverHost'];
    final webVersion = info['webVersion'];

    final serverText = serverVersion != null
        ? 'Server: $serverHost v$serverVersion'
        : 'Server: unreachable';
    final serverColor = serverVersion != null
        ? context.textMuted
        : EchoTheme.warning;

    return Column(
      children: [
        const SizedBox(height: 2),
        Text(
          serverText,
          textAlign: TextAlign.center,
          style: TextStyle(color: serverColor, fontSize: 11),
        ),
        if (kIsWeb && webVersion != null) ...[
          const SizedBox(height: 2),
          Text(
            'Web: v$webVersion',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.textMuted, fontSize: 11),
          ),
        ],
      ],
    );
  }
}
