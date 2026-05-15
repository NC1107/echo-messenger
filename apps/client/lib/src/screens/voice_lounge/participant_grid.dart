/// Participant grid + tile + avatar widgets used by the voice lounge.
library;

import 'dart:ui' show ImageFilter;

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

    final localIsSpeaking = voiceState.localAudioLevel > _attentionThreshold;
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
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: tiles.length,
      separatorBuilder: (context, index) => const SizedBox(width: 8),
      itemBuilder: (_, i) => SizedBox(width: 100, child: tiles[i]),
    );
  }

  Widget _buildGridLayout(List<Widget> tiles) {
    return Center(
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: tiles
            .map((t) => SizedBox(width: 112, height: 136, child: t))
            .toList(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Single participant tile
// ---------------------------------------------------------------------------

class ParticipantTile extends StatelessWidget {
  final String name;
  final String? avatarUrl;
  final bool hasVideo;
  final lk.VideoTrack? videoTrack;
  final bool mirror;
  final double audioLevel;
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
  Widget build(BuildContext context) {
    final isSpeaking = audioLevel > 0.01;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final double targetScale;
    final double targetOpacity;
    if (reduceMotion) {
      targetScale = 1.0;
      targetOpacity = 1.0;
    } else {
      switch (attention) {
        case ParticipantAttention.speaking:
          targetScale = 1.04;
          targetOpacity = 1.0;
        case ParticipantAttention.faded:
          targetScale = 0.96;
          targetOpacity = 0.62;
        case ParticipantAttention.idle:
          targetScale = 1.0;
          targetOpacity = 1.0;
      }
    }

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
                          videoTrack!,
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
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNameLabel(BuildContext context) {
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
    final participant = remoteParticipant;
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
          enabled: false,
          padding: EdgeInsets.zero,
          child: _ParticipantVolumePopover(
            participant: participant,
            name: name,
            onToggleMute: onMuteForMe,
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

  @override
  void initState() {
    super.initState();
    final identity = widget.participant.identity.isNotEmpty
        ? widget.participant.identity
        : widget.participant.sid.toString();
    _volume = ParticipantVolumeController.instance.volumeFor(identity);
  }

  Future<void> _onChanged(double next) async {
    setState(() => _volume = next);
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
    final verticalSlider = SizedBox(
      width: 36,
      height: 140,
      child: RotatedBox(
        quarterTurns: 3,
        child: SliderTheme(
          data: sliderTheme,
          child: Slider(value: _volume, min: 0, max: 1, onChanged: _onChanged),
        ),
      ),
    );

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
              headers: authToken != null
                  ? {'Authorization': 'Bearer $authToken'}
                  : null,
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
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return lk.VideoTrackRenderer(_track!, fit: lk.VideoViewFit.contain);
  }
}
