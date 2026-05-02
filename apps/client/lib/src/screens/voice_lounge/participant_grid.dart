/// Participant grid + tile + avatar widgets used by the voice lounge.
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../providers/livekit_voice_provider.dart';
import '../../theme/echo_theme.dart';
import '../../utils/canvas_utils.dart';
import '../../widgets/voice_speaking_ring.dart';

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

  @override
  Widget build(BuildContext context) {
    if (room == null) {
      return _buildPlaceholder(context, 'Connecting to voice...');
    }

    final tiles = <Widget>[
      if (room!.localParticipant != null)
        _buildLocalTile(room!.localParticipant!),
      ...room!.remoteParticipants.values.map(_buildRemoteTile),
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

  Widget _buildLocalTile(lk.LocalParticipant localParticipant) {
    final localVideo = localParticipant.videoTrackPublications
        .where(
          (pub) => pub.track != null && pub.source == lk.TrackSource.camera,
        )
        .firstOrNull;

    final localHasVideo =
        localVideo?.track != null && voiceState.isVideoEnabled;

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
      onTap: onTileTap != null ? () => onTileTap!('local') : null,
      authToken: authToken,
    );
  }

  Widget _buildRemoteTile(lk.RemoteParticipant participant) {
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
    this.onTap,
    this.onMuteForMe,
    this.authToken,
  });

  @override
  Widget build(BuildContext context) {
    final isSpeaking = audioLevel > 0.01;

    return GestureDetector(
      onTap: onTap,
      onSecondaryTapUp: !isLocal && onMuteForMe != null
          ? (details) => _showParticipantMenu(context, details.globalPosition)
          : null,
      onLongPress: !isLocal && onMuteForMe != null ? onMuteForMe : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
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
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      color: context.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: context.border),
      ),
      items: [
        PopupMenuItem(
          value: 'mute',
          child: Row(
            children: [
              Icon(Icons.volume_off, size: 16, color: context.textSecondary),
              const SizedBox(width: 8),
              Text(
                'Toggle mute for me',
                style: TextStyle(color: context.textPrimary, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'mute') onMuteForMe?.call();
    });
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
