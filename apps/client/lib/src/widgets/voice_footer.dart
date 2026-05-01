import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/channels_provider.dart';
import '../providers/livekit_voice_provider.dart';
import '../theme/echo_theme.dart';

/// Persistent footer shown at the bottom of the sidebar whenever
/// [livekitVoiceProvider.isActive] is true.
///
/// Displays the room name and a green pulsing indicator. Tapping the body
/// navigates back to the voice lounge via [onNavigateToLounge]. The
/// Disconnect button calls [leaveChannel] directly.
class VoiceFooter extends ConsumerStatefulWidget {
  final VoidCallback? onNavigateToLounge;

  const VoiceFooter({super.key, this.onNavigateToLounge});

  @override
  ConsumerState<VoiceFooter> createState() => _VoiceFooterState();
}

class _VoiceFooterState extends ConsumerState<VoiceFooter>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulseAnim = Tween<double>(
      begin: 0.5,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final voice = ref.watch(livekitVoiceProvider);

    if (!voice.isActive || voice.channelId == null) {
      if (_pulse.isAnimating) _pulse.stop();
      return const SizedBox.shrink();
    }

    // Start or resume the pulse animation when active.
    if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }

    final conversationId = voice.conversationId ?? '';
    final channelId = voice.channelId!;
    final channels = ref.watch(channelsProvider).channelsFor(conversationId);
    final channelName =
        channels.where((c) => c.id == channelId).firstOrNull?.name ?? 'Voice';

    return Semantics(
      label: 'Voice connected: $channelName',
      child: Material(
        color: EchoTheme.online.withValues(alpha: 0.08),
        child: InkWell(
          onTap: widget.onNavigateToLounge,
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: context.border, width: 1)),
            ),
            child: Row(
              children: [
                // Pulsing green dot
                FadeTransition(
                  opacity: _pulseAnim,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: EchoTheme.online,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    channelName,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Disconnect button
                Semantics(
                  label: 'Disconnect from voice',
                  button: true,
                  child: Tooltip(
                    message: 'Disconnect',
                    child: InkWell(
                      onTap: () => ref
                          .read(livekitVoiceProvider.notifier)
                          .leaveChannel(),
                      borderRadius: BorderRadius.circular(6),
                      child: const SizedBox(
                        width: 32,
                        height: 32,
                        child: Center(
                          child: Icon(
                            Icons.call_end,
                            size: 16,
                            color: EchoTheme.danger,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
