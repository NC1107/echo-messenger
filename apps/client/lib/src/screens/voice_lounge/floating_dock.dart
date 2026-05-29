/// Floating mac-style dock for the voice lounge.
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/livekit_voice/livekit_voice_provider.dart';
import '../../providers/screen_share_provider.dart';
import '../../providers/voice_settings_provider.dart';
import '../../theme/echo_theme.dart';
import '../../theme/motion_tokens.dart';
import 'lounge_constants.dart';
import 'screen_share_actions.dart';

class FloatingDock extends ConsumerStatefulWidget {
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
  ConsumerState<FloatingDock> createState() => _FloatingDockState();
}

class _FloatingDockState extends ConsumerState<FloatingDock> {
  /// True once the first leave tap is accepted. Latches to prevent a rapid
  /// double-tap from calling leaveChannel() twice while the first disconnect
  /// is in flight (null-deref / double-pop crash).
  bool _isLeaving = false;

  // Convenience getters so the build helpers read cleanly.
  LiveKitVoiceState get voiceState => widget.voiceState;
  VoiceSettingsState get voiceSettings => widget.voiceSettings;
  ScreenShareState get screenShare => widget.screenShare;
  String get conversationId => widget.conversationId;
  String get channelId => widget.channelId;
  bool get isDrawing => widget.isDrawing;
  VoidCallback get onToggleDrawing => widget.onToggleDrawing;
  DockSubmenu? get activeSubmenu => widget.activeSubmenu;
  ValueChanged<DockSubmenu> get onToggleSubmenu => widget.onToggleSubmenu;
  LayerLink get micLayerLink => widget.micLayerLink;
  LayerLink get cameraLayerLink => widget.cameraLayerLink;
  LayerLink get screenShareLayerLink => widget.screenShareLayerLink;
  LayerLink get drawingToolsLayerLink => widget.drawingToolsLayerLink;
  bool get spotlightMode => widget.spotlightMode;
  VoidCallback get onToggleSpotlight => widget.onToggleSpotlight;

  Future<void> _handleLeave() async {
    if (_isLeaving) return;
    setState(() => _isLeaving = true);

    // Capture provider notifier references BEFORE the first await so that
    // if the dock unmounts mid-teardown (parent HomeScreen swaps content,
    // foreground-service `ACTION_LEAVE` races the UI leave, CallKit
    // hang-up, etc.) we don't touch `ref` after dispose — `ref.read`
    // throws `StateError: Cannot use "ref"` once the ConsumerState is
    // gone. The notifiers themselves are keepAlive providers so the
    // captured handles stay valid across this widget's lifetime.
    final livekit = ref.read(livekitVoiceProvider.notifier);
    final screenShareNotifier = ref.read(screenShareProvider.notifier);

    // VL-10: on success the screen navigates away and this dock unmounts, so
    // the `_isLeaving` latch is intentionally left set (no setState on a dead
    // widget). On FAILURE, re-enable the button so a throw mid-teardown can't
    // permanently wedge it and strand the user in the lounge.
    try {
      if (screenShare.isScreenSharing) {
        await livekit.setScreenShareEnabled(false);
        screenShareNotifier.setLiveKitScreenShareActive(false);
      }
      // leaveChannel() already clears the server-side voice session via
      // channelsProvider.leaveVoiceChannel internally — don't call it twice.
      await livekit.leaveChannel();
    } catch (_) {
      if (mounted) setState(() => _isLeaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        // 24x24 BackdropFilter is one of CanvasKit/Firefox's worst hot
        // paths. Skip the blur on web; surface tint at 0.88 alpha already
        // reads as glass without the per-frame offscreen rasterise.
        child: _MaybeBlur(
          sigma: 24,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: context.surface.withValues(alpha: 0.88),
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
              children: _buildDockChildren(context),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildDockChildren(BuildContext context) {
    return [
      _buildMicButton(context),
      _buildDeafenButton(context),
      _buildCameraButton(context),
      if (kSupportsScreenShare) _buildScreenShareButton(context),
      if (!spotlightMode) _buildDrawButton(context),
      _dockDivider(context),
      _buildSpotlightToggle(context),
      _dockDivider(context),
      _buildLeaveButton(context),
    ];
  }

  Widget _buildMicButton(BuildContext context) {
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

  Widget _buildDeafenButton(BuildContext context) {
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

  Widget _buildCameraButton(BuildContext context) {
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

  Widget _buildScreenShareButton(BuildContext context) {
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

  Widget _buildDrawButton(BuildContext context) {
    return Semantics(
      label: 'Drawing tools',
      button: true,
      child: DockButtonWithSubmenu(
        icon: Icons.edit,
        tooltip: isDrawing ? 'Stop drawing' : 'Draw',
        isActive: isDrawing,
        activeColor: context.accent,
        onPressed: onToggleDrawing,
        onSubmenuTap: () => onToggleSubmenu(DockSubmenu.draw),
        submenuActive: activeSubmenu == DockSubmenu.draw,
        submenuLayerLink: drawingToolsLayerLink,
      ),
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

  Widget _buildLeaveButton(BuildContext context) {
    return _buildDockItem(
      context,
      icon: Icons.call_end,
      tooltip: _isLeaving ? 'Leaving…' : 'Leave',
      isActive: true,
      activeColor: EchoTheme.danger,
      isDestructive: true,
      // Null onPressed disables the button at the framework level once
      // leaving is in progress — prevents double-tap crash.
      onPressed: _isLeaving ? null : _handleLeave,
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
    // Nullable: passing null disables the button at the framework level
    // (InkWell.onTap = null) so in-progress actions like leave cannot be
    // triggered a second time.
    VoidCallback? onPressed,
  }) {
    final Color bgColor;
    final Color iconColor;
    if (isDestructive) {
      bgColor = (activeColor ?? EchoTheme.danger).withValues(
        alpha: onPressed == null ? 0.5 : 1.0,
      );
      iconColor = Colors.white.withValues(alpha: onPressed == null ? 0.5 : 1.0);
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
          onTap: onPressed == null
              ? null
              : () {
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
              width: 20,
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

/// BackdropFilter wrapper that skips the blur on web. CanvasKit's
/// Gaussian blur composites an offscreen GPU buffer per frame; on
/// Firefox/NVIDIA EGL that's enough to stall the lounge.
class _MaybeBlur extends StatelessWidget {
  final double sigma;
  final Widget child;
  const _MaybeBlur({required this.sigma, required this.child});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return child;
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: child,
    );
  }
}
