/// Floating mac-style dock for the voice lounge.
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/channels_provider.dart';
import '../../providers/livekit_voice_provider.dart';
import '../../providers/screen_share_provider.dart';
import '../../providers/voice_settings_provider.dart';
import '../../theme/echo_theme.dart';
import '../../theme/motion_tokens.dart';
import 'lounge_constants.dart';
import 'screen_share_actions.dart';

class FloatingDock extends ConsumerWidget {
  final LiveKitVoiceState voiceState;
  final VoiceSettingsState voiceSettings;
  final ScreenShareState screenShare;
  final String conversationId;
  final String channelId;
  final bool isDrawing;
  final VoidCallback onToggleDrawing;
  final DockSubmenu? activeSubmenu;
  final ValueChanged<DockSubmenu> onToggleSubmenu;
  final LayerLink micLayerLink;
  final LayerLink cameraLayerLink;
  final LayerLink screenShareLayerLink;
  final LayerLink drawingToolsLayerLink;
  final bool spotlightMode;
  final VoidCallback onToggleSpotlight;

  const FloatingDock({
    super.key,
    required this.voiceState,
    required this.voiceSettings,
    required this.screenShare,
    required this.conversationId,
    required this.channelId,
    required this.isDrawing,
    required this.onToggleDrawing,
    required this.activeSubmenu,
    required this.onToggleSubmenu,
    required this.micLayerLink,
    required this.cameraLayerLink,
    required this.screenShareLayerLink,
    required this.drawingToolsLayerLink,
    required this.spotlightMode,
    required this.onToggleSpotlight,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xE01C1C1E),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: context.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 40,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: _buildDockChildren(context, ref),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildDockChildren(BuildContext context, WidgetRef ref) {
    return [
      _buildMicButton(context, ref),
      _buildDeafenButton(context, ref),
      _buildCameraButton(context, ref),
      if (kSupportsScreenShare) _buildScreenShareButton(context, ref),
      if (!spotlightMode) _buildDrawButton(context, ref),
      _dockDivider(context),
      _buildSpotlightToggle(context),
      _dockDivider(context),
      _buildLeaveButton(context, ref),
    ];
  }

  Widget _buildMicButton(BuildContext context, WidgetRef ref) {
    return DockButtonWithSubmenu(
      icon: voiceSettings.selfMuted ? Icons.mic_off : Icons.mic,
      tooltip: voiceSettings.selfMuted ? 'Unmute' : 'Mute',
      isActive: voiceSettings.selfMuted,
      activeColor: EchoTheme.danger,
      onPressed: () async {
        final notifier = ref.read(voiceSettingsProvider.notifier);
        final nextMuted = !voiceSettings.selfMuted;
        await notifier.setSelfMuted(nextMuted);
        ref
            .read(livekitVoiceProvider.notifier)
            .setCaptureEnabled(!nextMuted && !voiceSettings.selfDeafened);
      },
      onSubmenuTap: () => onToggleSubmenu(DockSubmenu.mic),
      submenuActive: activeSubmenu == DockSubmenu.mic,
      submenuLayerLink: micLayerLink,
    );
  }

  Widget _buildDeafenButton(BuildContext context, WidgetRef ref) {
    return _buildDockItem(
      context,
      icon: voiceSettings.selfDeafened ? Icons.headset_off : Icons.headset,
      tooltip: voiceSettings.selfDeafened ? 'Undeafen' : 'Deafen',
      isActive: voiceSettings.selfDeafened,
      activeColor: EchoTheme.danger,
      onPressed: () async {
        final notifier = ref.read(voiceSettingsProvider.notifier);
        final nextDeafened = !voiceSettings.selfDeafened;
        await notifier.setSelfDeafened(nextDeafened);
        await ref.read(livekitVoiceProvider.notifier).setDeafened(nextDeafened);
      },
    );
  }

  Widget _buildCameraButton(BuildContext context, WidgetRef ref) {
    return DockButtonWithSubmenu(
      icon: voiceState.isVideoEnabled ? Icons.videocam : Icons.videocam_off,
      tooltip: voiceState.isVideoEnabled ? 'Turn off camera' : 'Turn on camera',
      isActive: voiceState.isVideoEnabled,
      activeColor: context.accent,
      onPressed: () async {
        await ref.read(livekitVoiceProvider.notifier).toggleVideo();
      },
      onSubmenuTap: () => onToggleSubmenu(DockSubmenu.camera),
      submenuActive: activeSubmenu == DockSubmenu.camera,
      submenuLayerLink: cameraLayerLink,
    );
  }

  Widget _buildScreenShareButton(BuildContext context, WidgetRef ref) {
    return DockButtonWithSubmenu(
      icon: screenShare.isScreenSharing
          ? Icons.stop_screen_share
          : Icons.screen_share,
      tooltip: screenShare.isScreenSharing ? 'Stop sharing' : 'Share screen',
      isActive: screenShare.isScreenSharing,
      activeColor: EchoTheme.online,
      onPressed: () => toggleScreenShare(context, ref),
      onSubmenuTap: () => onToggleSubmenu(DockSubmenu.screenShare),
      submenuActive: activeSubmenu == DockSubmenu.screenShare,
      submenuLayerLink: screenShareLayerLink,
    );
  }

  Widget _buildDrawButton(BuildContext context, WidgetRef ref) {
    return DockButtonWithSubmenu(
      icon: Icons.edit,
      tooltip: isDrawing ? 'Stop drawing' : 'Draw',
      isActive: isDrawing,
      activeColor: context.accent,
      onPressed: onToggleDrawing,
      onSubmenuTap: () => onToggleSubmenu(DockSubmenu.draw),
      submenuActive: activeSubmenu == DockSubmenu.draw,
      submenuLayerLink: drawingToolsLayerLink,
    );
  }

  Widget _buildSpotlightToggle(BuildContext context) {
    return _buildDockItem(
      context,
      icon: spotlightMode ? Icons.grid_view : Icons.people,
      tooltip: spotlightMode ? 'Canvas view' : 'Spotlight view',
      isActive: spotlightMode,
      activeColor: context.accent,
      onPressed: onToggleSpotlight,
    );
  }

  Widget _buildLeaveButton(BuildContext context, WidgetRef ref) {
    return _buildDockItem(
      context,
      icon: Icons.call_end,
      tooltip: 'Leave',
      isActive: true,
      activeColor: EchoTheme.danger,
      isDestructive: true,
      onPressed: () async {
        if (screenShare.isScreenSharing) {
          await ref
              .read(livekitVoiceProvider.notifier)
              .setScreenShareEnabled(false);
          ref
              .read(screenShareProvider.notifier)
              .setLiveKitScreenShareActive(false);
        }
        await ref
            .read(channelsProvider.notifier)
            .leaveVoiceChannel(conversationId, channelId);
        await ref.read(livekitVoiceProvider.notifier).leaveChannel();
      },
    );
  }

  static Widget _dockDivider(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: context.border.withValues(alpha: 0.4),
    );
  }

  static Widget _buildDockItem(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    bool isActive = false,
    Color? activeColor,
    bool isDestructive = false,
    required VoidCallback onPressed,
  }) {
    final Color bgColor;
    final Color iconColor;
    if (isDestructive) {
      bgColor = activeColor ?? EchoTheme.danger;
      iconColor = Colors.white;
    } else if (isActive) {
      bgColor = activeColor ?? context.accent;
      iconColor = Colors.white;
    } else {
      bgColor = Colors.transparent;
      iconColor = context.textPrimary;
    }

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            HapticFeedback.lightImpact();
            onPressed();
          },
          borderRadius: BorderRadius.circular(20),
          child: AnimatedContainer(
            duration: MotionDurations.quick,
            curve: MotionCurves.entrance,
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
            child: Icon(icon, size: 18, color: iconColor),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dock button with paired 3-dot submenu
// ---------------------------------------------------------------------------

class DockButtonWithSubmenu extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isActive;
  final Color? activeColor;
  final VoidCallback onPressed;
  final VoidCallback? onSubmenuTap;
  final bool submenuActive;
  final LayerLink? submenuLayerLink;

  const DockButtonWithSubmenu({
    super.key,
    required this.icon,
    required this.tooltip,
    this.isActive = false,
    this.activeColor,
    required this.onPressed,
    this.onSubmenuTap,
    this.submenuActive = false,
    this.submenuLayerLink,
  });

  @override
  Widget build(BuildContext context) {
    final Color bgColor;
    final Color iconColor;
    if (isActive) {
      bgColor = activeColor ?? context.accent;
      iconColor = Colors.white;
    } else {
      bgColor = Colors.transparent;
      iconColor = context.textPrimary;
    }

    Widget? buildSubmenuTrigger() {
      if (onSubmenuTap == null) return null;
      final arrowColor = submenuActive
          ? (activeColor ?? context.accent)
          : context.textMuted;
      final arrowIcon = submenuActive ? Icons.expand_less : Icons.expand_more;
      final trigger = Tooltip(
        message: '$tooltip options',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              onSubmenuTap!();
            },
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 14,
              height: 44,
              child: Icon(arrowIcon, size: 12, color: arrowColor),
            ),
          ),
        ),
      );

      if (submenuLayerLink != null) {
        return CompositedTransformTarget(
          link: submenuLayerLink!,
          child: trigger,
        );
      }
      return trigger;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: tooltip,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                HapticFeedback.lightImpact();
                onPressed();
              },
              borderRadius: BorderRadius.circular(20),
              child: AnimatedContainer(
                duration: MotionDurations.quick,
                curve: MotionCurves.entrance,
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: bgColor,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 18, color: iconColor),
              ),
            ),
          ),
        ),
        if (onSubmenuTap != null) buildSubmenuTrigger()!,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Drawing tools non-modal panel
// ---------------------------------------------------------------------------

class DrawingToolsPanel extends StatelessWidget {
  final Widget child;

  const DrawingToolsPanel({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 220),
      decoration: BoxDecoration(
        color: context.surface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
