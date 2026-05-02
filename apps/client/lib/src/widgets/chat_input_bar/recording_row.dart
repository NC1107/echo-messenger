import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';
import 'live_waveform_bars.dart';
import 'pulsing_dot.dart';

/// Recording overlay shown in place of the input row while recording.
class RecordingRow extends StatelessWidget {
  final Duration recordingDuration;
  final List<double> recordingAmplitudes;
  final VoidCallback onCancel;
  final VoidCallback onStop;

  const RecordingRow({
    super.key,
    required this.recordingDuration,
    required this.recordingAmplitudes,
    required this.onCancel,
    required this.onStop,
  });

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: EchoTheme.danger.withValues(alpha: 0.6),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: 12),
          // Pulsing red dot
          const PulsingDot(color: EchoTheme.danger),
          const SizedBox(width: 8),
          Text(
            _formatDuration(recordingDuration),
            style: const TextStyle(
              color: EchoTheme.danger,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          // Mini waveform bars (live amplitude)
          Expanded(child: LiveWaveformBars(amplitudes: recordingAmplitudes)),
          const SizedBox(width: 8),
          // Cancel button
          IconButton(
            icon: Icon(
              Icons.delete_outline,
              color: context.textMuted,
              size: 20,
            ),
            tooltip: 'Cancel recording',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: onCancel,
          ),
          // Stop / send button
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: GestureDetector(
              onTap: onStop,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      color: EchoTheme.danger,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.stop_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
