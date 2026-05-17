/// Participant grid + tile + avatar widgets used by the voice lounge.
library;

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../providers/livekit_voice_provider.dart';
import '../../theme/echo_theme.dart';
import '../../theme/motion_tokens.dart';
import '../../utils/canvas_utils.dart';
import '../../widgets/voice/participant_attention.dart';
import '../../widgets/voice_speaking_ring.dart';
import 'participant_volume_controller.dart';

class ParticipantGrid extends StatelessWidget {
  final lk.Room? room;
  final LiveKitVoiceState voiceState;
  final String? localAvatarUrl;
  final Map<String, String?> memberAvatars;
  final bool compact;
  final String? authToken;

  /// Called with the tile key when the user taps a tile to focus it.
  final void Function(String key)? onTileTap;

  const ParticipantGrid({
    super.key,
    required this.room,
    required this.voiceState,
    this.localAvatarUrl,
    this.memberAvatars = const {},
    this.compact = false,
    this.onTileTap,
    this.authToken,
  });

  /// Phase 3c threshold: matches `_ParticipantInfo.isSpeaking` in
  /// voice_canvas.dart so attention behaves consistently between
  /// grid and canvas modes.
  static const double _attentionThreshold = 0.05;

  bool get _anyoneSpeaking {
    if (voiceState.activeSpeakerIdentities.isNotEmpty) return true;
    if (voiceState.localAudioLevel > _attentionThreshold) return true;
    for (final level in voiceState.peerAudioLevels.values) {
      if (level > _attentionThreshold) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (room == null) {
      return _buildPlaceholder(context, 'Connecting to voice...');
    }

    // Phase 3c: precompute room attention once per build so each
    // tile renders fade/scale relative to whoever is on the air.
    final anyoneSpeaking = _anyoneSpeaking;

    final tiles = <Widget>[
      if (room!.localParticipant != null)
        _buildLocalTile(room!.localParticipant!, anyoneSpeaking),
      ...room!.remoteParticipants.values.map(
        (p) => _buildRemoteTile(p, anyoneSpeaking),
      ),
    ];

    if (tiles.isEmpty) {
      return _buildPlaceholder(context, 'No participants');
    }

    if (compact) {
      return _buildCompactLayout(tiles);
    }
    return _buildGridLayout(tiles);
  }

  Widget _buildPlaceholder(BuildContext context, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Text(
          message,
          style: TextStyle(color: context.textMuted, fontSize: 14),
        ),
      ),
    );
  }

  Widget _buildLocalTile(
    lk.LocalParticipant localParticipant,
    bool anyoneSpeaking,
  ) {
    final localVideo = localParticipant.videoTrackPublications
        .where(
          (pub) => pub.track != null && pub.source == lk.TrackSource.camera,
        )
        .firstOrNull;

    final localHasVideo =
        localVideo?.track != null && voiceState.isVideoEnabled;

    final localIdentity = room!.localParticipant?.identity ?? '';
    final localIsSpeaking =
        voiceState.localAudioLevel > _attentionThreshold ||
        (localIdentity.isNotEmpty &&
            voiceState.activeSpeakerIdentities.contains(localIdentity));
    final attention = attentionFor(
      isSpeaking: localIsSpeaking,
      anyoneElseSpeaking: anyoneSpeaking && !localIsSpeaking,
    );

    return ParticipantTile(
      key: const ValueKey('local'),
      name: 'You',
      avatarUrl: localAvatarUrl,
      hasVideo: localHasVideo,
      videoTrack: localHasVideo ? localVideo?.track as lk.VideoTrack? : null,
      mirror: true,
      audioLevel: voiceState.localAudioLevel,
      isSpeakingHint: localIsSpeaking,
      isMuted: !voiceState.isCaptureEnabled,
      isLocal: true,
      attention: attention,
      onTap: onTileTap != null ? () => onTileTap!('local') : null,
      authToken: authToken,
    );
  }

  Widget _buildRemoteTile(
    lk.RemoteParticipant participant,
    bool anyoneSpeaking,
  ) {
    final displayName = participantDisplayName(participant);
    final videoTrack = participant.videoTrackPublications
        .where(
          (pub) =>
              pub.track != null &&
              pub.track is lk.VideoTrack &&
              pub.source == lk.TrackSource.camera,
        )
        .firstOrNull;

    final identity = participant.identity.isNotEmpty
        ? participant.identity
        : participant.sid.toString();
    final audioLevel = voiceState.peerAudioLevels[identity] ?? 0.0;

    // Speaker outline reacts to whichever fires first: the server-push
    // ActiveSpeakersChangedEvent OR the local audio-level threshold (#907).
    final remoteIsSpeaking =
        audioLevel > _attentionThreshold ||
        voiceState.activeSpeakerIdentities.contains(identity);
    final attention = attentionFor(
      isSpeaking: remoteIsSpeaking,
      anyoneElseSpeaking: anyoneSpeaking && !remoteIsSpeaking,
    );

    return ParticipantTile(
      key: ValueKey('remote-${participant.sid}'),
      name: displayName,
      avatarUrl: memberAvatars[displayName],
      hasVideo: videoTrack?.track != null,
      videoTrack: videoTrack?.track as lk.VideoTrack?,
      mirror: false,
      audioLevel: audioLevel,
      isSpeakingHint: remoteIsSpeaking,
      isMuted: participant.isMuted,
      connectionState: voiceState.peerConnectionStates[identity],
      attention: attention,
      onTap: onTileTap != null
          ? () => onTileTap!('remote-${participant.sid}')
          : null,
      onMuteForMe: () async {
        for (final pub in participant.audioTrackPublications) {
          final track = pub.track;
          if (track != null) {
            if (pub.subscribed) {
              await track.disable();
            } else {
              await track.enable();
            }
          }
        }
      },
      remoteParticipant: participant,
      identity: identity,
      authToken: authToken,
    );
  }

  Widget _buildCompactLayout(List<Widget> tiles) {
    return Scrollbar(
      thumbVisibility: false,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: tiles.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (_, i) => SizedBox(width: 100, child: tiles[i]),
      ),
    );
  }

  Widget _buildGridLayout(List<Widget> tiles) {
    return OrientationBuilder(
      builder: (context, orientation) {
        final crossAxisCount = orientation == Orientation.portrait ? 2 : 3;
        return Center(
          child: GridView.count(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 112 / 136,
            children: tiles,
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Single participant tile
// ---------------------------------------------------------------------------

class ParticipantTile extends StatefulWidget {
  final String name;
  final String? avatarUrl;
  final bool hasVideo;
  final lk.VideoTrack? videoTrack;
  final bool mirror;
  final double audioLevel;

  /// External speaking hint that fires off either the LiveKit
  /// `ActiveSpeakersChangedEvent` server push OR a level-threshold check in
  /// the parent grid — whichever lands first (#907). When true, the ring and
  /// glow flip on immediately without waiting for [audioLevel] to climb.
  final bool isSpeakingHint;

  final bool isMuted;
  final String? connectionState;
  final bool isLocal;
  final VoidCallback? onTap;
  final VoidCallback? onMuteForMe;
  final String? authToken;

  /// Remote participant handle — required for the per-peer volume slider in
  /// the secondary-tap / long-press popover. Null for the local tile (which
  /// has no slider — you can't adjust your own outgoing volume from here).
  final lk.RemoteParticipant? remoteParticipant;

  /// Stable identity used as the key into [ParticipantVolumeController].
  final String? identity;

  /// Phase 3c: room-level attention (speaking / faded / idle).
  /// Drives the tile's scale + opacity so non-speakers fade back when
  /// someone else is on the air.
  final ParticipantAttention attention;

  const ParticipantTile({
    super.key,
    required this.name,
    this.avatarUrl,
    required this.hasVideo,
    this.videoTrack,
    this.mirror = false,
    this.audioLevel = 0.0,
    this.isSpeakingHint = false,
    this.isMuted = false,
    this.connectionState,
    this.isLocal = false,
    this.attention = ParticipantAttention.idle,
    this.onTap,
    this.onMuteForMe,
    this.authToken,
    this.remoteParticipant,
    this.identity,
  });

  @override
  State<ParticipantTile> createState() => _ParticipantTileState();
}

class _ParticipantTileState extends State<ParticipantTile> {
  /// Grace period that keeps `isSpeaking` true for a brief window after the
  /// last above-threshold sample, so the ring doesn't flicker during natural
  /// pauses mid-sentence (#907).
  static const Duration _speakingDecay = Duration(milliseconds: 200);

  bool _isSpeaking = false;
  Timer? _decayTimer;

  @override
  void initState() {
    super.initState();
    _isSpeaking = _rawSpeaking();
  }

  @override
  void didUpdateWidget(covariant ParticipantTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final raw = _rawSpeaking();
    if (raw) {
      _decayTimer?.cancel();
      _decayTimer = null;
      if (!_isSpeaking) {
        setState(() => _isSpeaking = true);
      }
    } else if (_isSpeaking && _decayTimer == null) {
      _decayTimer = Timer(_speakingDecay, () {
        if (!mounted) return;
        if (!_rawSpeaking()) {
          setState(() => _isSpeaking = false);
        }
        _decayTimer = null;
      });
    }
  }

  @override
  void dispose() {
    _decayTimer?.cancel();
    super.dispose();
  }

  bool _rawSpeaking() => widget.isSpeakingHint || widget.audioLevel > 0.01;

  @override
  Widget build(BuildContext context) {
    final isSpeaking = _isSpeaking;
    final attention = widget.attention;
    final isLocal = widget.isLocal;
    final remoteParticipant = widget.remoteParticipant;
    final audioLevel = widget.audioLevel;
    final hasVideo = widget.hasVideo;
    final videoTrack = widget.videoTrack;
    final mirror = widget.mirror;
    final name = widget.name;
    final avatarUrl = widget.avatarUrl;
    final authToken = widget.authToken;
    final onTap = widget.onTap;
    final (targetScale, targetOpacity) = _computeAttentionMetrics(
      context,
      attention,
    );

    return AnimatedOpacity(
      opacity: targetOpacity,
      duration: MotionDurations.standard,
      curve: MotionCurves.entrance,
      child: AnimatedScale(
        scale: targetScale,
        duration: MotionDurations.quick,
        curve: MotionCurves.emphasis,
        child: GestureDetector(
          onTap: onTap,
          onSecondaryTapUp: !isLocal && remoteParticipant != null
              ? (details) =>
                    _showParticipantMenu(context, details.globalPosition)
              : null,
          onLongPressStart: !isLocal && remoteParticipant != null
              ? (details) =>
                    _showParticipantMenu(context, details.globalPosition)
              : null,
          child: AnimatedContainer(
            duration: MotionDurations.standard,
            curve: MotionCurves.entrance,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSpeaking ? EchoTheme.online : context.border,
                width: isSpeaking ? 2.0 : 1.0,
              ),
              boxShadow: isSpeaking
                  ? [
                      BoxShadow(
                        color: EchoTheme.online.withValues(alpha: 0.3),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            clipBehavior: Clip.antiAlias,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
              // RepaintBoundary isolates the blur layer so audio-level
              // rebuilds (~10 Hz) don't re-rasterise the BackdropFilter
              // for every tile in the grid.
              child: RepaintBoundary(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    color: context.surface.withValues(alpha: 0.30),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Video or avatar
                        if (hasVideo && videoTrack != null)
                          lk.VideoTrackRenderer(
                            videoTrack,
                            fit: lk.VideoViewFit.cover,
                            mirrorMode: mirror
                                ? lk.VideoViewMirrorMode.mirror
                                : lk.VideoViewMirrorMode.off,
                          )
                        else
                          AvatarCircle(
                            name: name,
                            avatarUrl: avatarUrl,
                            audioLevel: audioLevel,
                            authToken: authToken,
                          ),
                        _buildNameLabel(context),
                        // Long-press affordance (remote participants only)
                        if (!isLocal && remoteParticipant != null)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Tooltip(
                              message: 'Long-press for options',
                              child: Icon(
                                Icons.more_vert,
                                size: 10,
                                color: Colors.white.withValues(alpha: 0.6),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  (double, double) _computeAttentionMetrics(
    BuildContext context,
    ParticipantAttention attention,
  ) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (reduceMotion) {
      return (1.0, 1.0);
    }

    return switch (attention) {
      ParticipantAttention.speaking => (1.04, 1.0),
      ParticipantAttention.faded => (0.96, 0.62),
      ParticipantAttention.idle => (1.0, 1.0),
    };
  }

  Widget _buildNameLabel(BuildContext context) {
    final name = widget.name;
    final isMuted = widget.isMuted;
    final connectionState = widget.connectionState;
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isMuted)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.mic_off, size: 14, color: EchoTheme.danger),
              ),
            if (connectionState != null && connectionState != 'connected')
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(
                  Icons.signal_cellular_alt,
                  size: 14,
                  color: connectionState == 'reconnecting'
                      ? EchoTheme.warning
                      : context.textMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showParticipantMenu(BuildContext context, Offset position) {
    final participant = widget.remoteParticipant;
    if (participant == null) return;

    final overlay =
        Overlay.of(context, rootOverlay: true).context.findRenderObject()
            as RenderBox?;
    final overlaySize = overlay?.size ?? MediaQuery.of(context).size;

    showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlaySize.width - position.dx,
        overlaySize.height - position.dy,
      ),
      color: context.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: context.border),
      ),
      items: [
        PopupMenuItem<void>(
          // enabled: true (default) keeps the slider track + thumb rendered in
          // their normal theme colors. We override [onTap] to null so tapping
          // the slider doesn't dismiss the menu — the popover handles its own
          // dismissal via the "Toggle mute for me" row.
          onTap: null,
          padding: EdgeInsets.zero,
          child: _ParticipantVolumePopover(
            participant: participant,
            name: widget.name,
            onToggleMute: widget.onMuteForMe,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Volume slider popover (per-participant)
// ---------------------------------------------------------------------------

class _ParticipantVolumePopover extends StatefulWidget {
  final lk.RemoteParticipant participant;
  final String name;
  final VoidCallback? onToggleMute;

  const _ParticipantVolumePopover({
    required this.participant,
    required this.name,
    this.onToggleMute,
  });

  @override
  State<_ParticipantVolumePopover> createState() =>
      _ParticipantVolumePopoverState();
}

class _ParticipantVolumePopoverState extends State<_ParticipantVolumePopover> {
  late double _volume;

  /// `flutter_webrtc`'s `Helper.setVolume` is a no-op on the Windows native
  /// backend (#909). We keep the slider visible so users can see the control
  /// exists, but render it disabled with a tooltip explaining why.
  bool get _perUserVolumeSupported {
    if (kIsWeb) return true;
    return defaultTargetPlatform != TargetPlatform.windows;
  }

  static const String _windowsTooltip =
      'Per-user volume is not supported on Windows yet (flutter_webrtc limitation)';

  @override
  void initState() {
    super.initState();
    final identity = widget.participant.identity.isNotEmpty
        ? widget.participant.identity
        : widget.participant.sid.toString();
    _volume = ParticipantVolumeController.instance.volumeFor(identity);
  }

  /// Visual-only update while the user is dragging. We deliberately do NOT
  /// call [ParticipantVolumeController.setVolume] from here — overlapping
  /// async slider events can resolve out of order and leave the WebRTC track
  /// gain at a stale value. The commit happens once on [_onChangeEnd].
  void _onChanged(double next) {
    setState(() => _volume = next);
  }

  Future<void> _onChangeEnd(double next) async {
    await ParticipantVolumeController.instance.setVolume(
      widget.participant,
      next,
    );
  }

  @override
  Widget build(BuildContext context) {
    final percent = (_volume * 100).round();
    final sliderTheme = SliderTheme.of(context).copyWith(
      trackHeight: 4,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      activeTrackColor: context.accent,
      inactiveTrackColor: context.border,
      thumbColor: context.accent,
      overlayColor: context.accent.withValues(alpha: 0.18),
    );

    // Vertical slider: rotate a horizontal Slider 90° counter-clockwise so
    // the high end sits at the top. SfSlider isn't a project dep, and a
    // hand-rolled GestureDetector slider would skip a11y/keyboard support
    // — rotating the framework Slider keeps semantics intact.
    final supported = _perUserVolumeSupported;
    Widget verticalSlider = SizedBox(
      width: 36,
      height: 140,
      child: RotatedBox(
        quarterTurns: 3,
        child: SliderTheme(
          data: sliderTheme,
          child: Slider(
            value: _volume,
            min: 0,
            max: 1,
            onChanged: supported ? _onChanged : null,
            onChangeEnd: supported ? _onChangeEnd : null,
          ),
        ),
      ),
    );
    if (!supported) {
      verticalSlider = Tooltip(message: _windowsTooltip, child: verticalSlider);
    }

    return SizedBox(
      width: 180,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: double.infinity,
              child: Text(
                widget.name,
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '$percent%',
              style: TextStyle(color: context.textMuted, fontSize: 11),
            ),
            const SizedBox(height: 4),
            Icon(Icons.volume_up, size: 16, color: context.textMuted),
            verticalSlider,
            Icon(
              _volume <= 0.001 ? Icons.volume_off : Icons.volume_down,
              size: 16,
              color: context.textMuted,
            ),
            if (widget.onToggleMute != null) ...[
              const SizedBox(height: 6),
              const Divider(height: 1),
              const SizedBox(height: 4),
              InkWell(
                onTap: () {
                  Navigator.of(context).pop();
                  widget.onToggleMute?.call();
                },
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.volume_off,
                        size: 16,
                        color: context.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Toggle mute for me',
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Avatar circle (shown when no video)
// ---------------------------------------------------------------------------

class AvatarCircle extends StatelessWidget {
  final String name;
  final String? avatarUrl;
  final double audioLevel;
  final String? authToken;

  const AvatarCircle({
    super.key,
    required this.name,
    this.avatarUrl,
    required this.audioLevel,
    this.authToken,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    // Generate a stable color from the name
    final hue = (name.hashCode % 360).abs().toDouble();
    final avatarColor = HSLColor.fromAHSL(1.0, hue, 0.5, 0.35).toColor();

    const double avatarSize = 80;

    final circle = Container(
      width: avatarSize,
      height: avatarSize,
      decoration: BoxDecoration(shape: BoxShape.circle, color: avatarColor),
      clipBehavior: Clip.antiAlias,
      child: avatarUrl != null
          ? Image.network(
              avatarUrl!,
              headers: _getAuthHeaders(authToken),
              fit: BoxFit.cover,
              width: avatarSize,
              height: avatarSize,
              errorBuilder: (_, _, _) => Center(
                child: Text(
                  initial,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
          : Center(
              child: Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
    );

    return Center(
      child: VoiceSpeakingRing(audioLevel: audioLevel, child: circle),
    );
  }
}

// ---------------------------------------------------------------------------
// Lightweight screen share track renderer for inline windows
// ---------------------------------------------------------------------------

/// Renders just the local screen share video track without extra decoration.
/// Used inside [DraggableScreenShareWindow] which already provides container styling.
///
/// The screen share track may not be available immediately after the user
/// selects a screen to share (LiveKit publishes asynchronously). This widget
/// retries on a short timer until the track appears or the widget is disposed.
class LocalScreenShareTrack extends StatefulWidget {
  final WidgetRef ref;
  const LocalScreenShareTrack({super.key, required this.ref});

  @override
  State<LocalScreenShareTrack> createState() => _LocalScreenShareTrackState();
}

class _LocalScreenShareTrackState extends State<LocalScreenShareTrack> {
  lk.VideoTrack? _track;
  lk.EventsListener<lk.RoomEvent>? _listener;

  @override
  void initState() {
    super.initState();
    _resolveTrack();
    _attachListener();
  }

  @override
  void dispose() {
    _listener?.dispose();
    _listener = null;
    super.dispose();
  }

  void _attachListener() {
    final room = widget.ref.read(livekitVoiceProvider.notifier).room;
    if (room == null) return;
    _listener = room.createListener();
    _listener!.on<lk.LocalTrackPublishedEvent>((_) {
      _resolveTrack();
    });
  }

  void _resolveTrack() {
    final room = widget.ref.read(livekitVoiceProvider.notifier).room;
    final localParticipant = room?.localParticipant;
    if (localParticipant == null) return;

    final screenPub = localParticipant.videoTrackPublications
        .where(
          (pub) =>
              pub.track != null &&
              pub.source == lk.TrackSource.screenShareVideo,
        )
        .firstOrNull;
    final track = screenPub?.track as lk.VideoTrack?;
    if (track != null && track != _track) {
      setState(() => _track = track);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_track == null) {
      // Black background prevents the BackdropFilter in sibling ParticipantTile
      // widgets from sampling a grey surface and washing out the lounge UI
      // while the screen-share track resolves (#17a).
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white54,
            ),
          ),
        ),
      );
    }
    return lk.VideoTrackRenderer(_track!, fit: lk.VideoViewFit.contain);
  }
}

Map<String, String>? _getAuthHeaders(String? authToken) {
  return authToken != null ? {'Authorization': 'Bearer $authToken'} : null;
}
