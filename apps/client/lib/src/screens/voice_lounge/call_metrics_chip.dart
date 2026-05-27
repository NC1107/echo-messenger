import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/livekit_voice/livekit_voice_provider.dart';
import '../../theme/echo_theme.dart';

/// Pill that shows elapsed call duration (MM:SS) and round-trip ping for the
/// active voice session. State comes from [livekitVoiceProvider] —
/// [LiveKitVoiceState.callStartedAt] is stamped when the user joins a
/// channel, and [LiveKitVoiceState.rttMs] is polled by `RtcStatsPoll`
/// every 2 seconds. Duration ticks locally at 1 Hz so we don't have to
/// rebroadcast clock state from the provider.
class CallMetricsChip extends ConsumerStatefulWidget {
  const CallMetricsChip({super.key});

  @override
  ConsumerState<CallMetricsChip> createState() => _CallMetricsChipState();
}

class _CallMetricsChipState extends ConsumerState<CallMetricsChip> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final voice = ref.watch(livekitVoiceProvider);
    final startedAt = voice.callStartedAt;
    if (startedAt == null) return const SizedBox.shrink();

    final elapsed = DateTime.now().difference(startedAt);
    final duration = _formatDuration(elapsed);
    final rtt = voice.rttMs;
    final pingColor = _pingColor(rtt);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.timer_outlined, size: 13, color: Colors.white70),
          const SizedBox(width: 4),
          Text(
            duration,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w600,
            ),
          ),
          if (rtt > 0) ...[
            Container(
              width: 1,
              height: 12,
              color: Colors.white24,
              margin: const EdgeInsets.symmetric(horizontal: 8),
            ),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: pingColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              '${rtt.round()} ms',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  static Color _pingColor(double rtt) {
    if (rtt <= 100) return EchoTheme.online;
    if (rtt <= 250) return EchoTheme.warning;
    return EchoTheme.danger;
  }
}
