import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../models/canvas_models.dart';
import '../providers/auth_provider.dart';
import '../providers/canvas_provider.dart';
import '../providers/livekit_voice/livekit_voice_provider.dart';
import '../theme/echo_theme.dart';
import '../theme/motion_tokens.dart';
import '../utils/canvas_utils.dart';
import 'puck_trail.dart';
import 'voice/participant_attention.dart';
import 'voice_speaking_ring.dart';

const double _kAvatarSize = 48.0;
const double _kAvatarHalfSize = _kAvatarSize / 2;

/// Interactive voice-lounge canvas.
///
/// Features:
///   • Draggable circular avatars with speaking ring
///   • Freehand drawing (pen + eraser) via CustomPainter
///   • Paste/drop images pinned to the canvas
///   • All state synced in real-time via WebSocket
///   • Persistent board state loaded from the server on join
class VoiceCanvas extends ConsumerStatefulWidget {
  final String channelId;
  final String conversationId;
  final lk.Room? room;
  final LiveKitVoiceState voiceState;
  final String? localAvatarUrl;
  final void Function(lk.VideoTrack track, bool mirror)? onVideoDoubleTap;

  const VoiceCanvas({
    super.key,
    required this.channelId,
    required this.conversationId,
    required this.voiceState,
    this.room,
    this.localAvatarUrl,
    this.onVideoDoubleTap,
  });

  @override
  ConsumerState<VoiceCanvas> createState() => _VoiceCanvasState();
}

/// Globally-accessible key used to capture the active voice-lounge canvas
/// as a PNG. The Stack inside this RepaintBoundary holds the strokes,
/// images, and avatar tiles. Reset whenever the canvas widget rebuilds so
/// the key always points at the currently mounted instance.
final GlobalKey voiceCanvasRepaintKey = GlobalKey(
  debugLabel: 'voice-canvas-repaint',
);

class _VoiceCanvasState extends ConsumerState<VoiceCanvas> {
  final _canvasKey = GlobalKey();

  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(canvasProvider.notifier)
          .attach(widget.conversationId, widget.channelId);
    });
  }

  @override
  void didUpdateWidget(VoiceCanvas old) {
    super.didUpdateWidget(old);
    if (old.channelId != widget.channelId ||
        old.conversationId != widget.conversationId) {
      ref
          .read(canvasProvider.notifier)
          .attach(widget.conversationId, widget.channelId);
    }
  }

  @override
  void dispose() {
    try {
      ref.read(canvasProvider.notifier).detach();
    } catch (_) {
      // Widget may already be unmounted; ignore.
    }
    _focusNode.dispose();
    super.dispose();
  }

  Size _canvasSize() {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.size ?? const Size(400, 300);
  }

  CanvasPoint _toNormalized(Offset local) {
    final size = _canvasSize();
    return CanvasPoint(
      x: (local.dx / size.width).clamp(0.0, 1.0),
      y: (local.dy / size.height).clamp(0.0, 1.0),
    );
  }

  Offset _toLocal(CanvasPoint norm) {
    final size = _canvasSize();
    return Offset(norm.x * size.width, norm.y * size.height);
  }

  @override
  Widget build(BuildContext context) {
    final canvas = ref.watch(canvasProvider);
    final authState = ref.watch(authProvider);
    final myUserId = authState.userId ?? '';
    final tool = canvas.selectedTool;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) => _handleKeyEvent(event),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        child: Column(
          children: [
            Expanded(
              child: ClipRect(
                child: RepaintBoundary(
                  key: voiceCanvasRepaintKey,
                  child: Stack(
                    key: _canvasKey,
                    children: [
                      Positioned.fill(
                        child: _DrawingLayer(
                          canvas: canvas,
                          onPointerDown: (offset) {
                            if (tool == CanvasTool.pen ||
                                tool == CanvasTool.eraser) {
                              ref
                                  .read(canvasProvider.notifier)
                                  .startStroke(_toNormalized(offset));
                            }
                          },
                          onPointerMove: (offset) {
                            if (tool == CanvasTool.pen ||
                                tool == CanvasTool.eraser) {
                              ref
                                  .read(canvasProvider.notifier)
                                  .continueStroke(_toNormalized(offset));
                            }
                          },
                          onPointerUp: () {
                            if (tool == CanvasTool.pen ||
                                tool == CanvasTool.eraser) {
                              ref.read(canvasProvider.notifier).endStroke();
                            }
                          },
                        ),
                      ),
                      ..._buildImages(canvas, authState),
                      ..._buildAvatars(canvas, myUserId, authState),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildAvatars(
    CanvasState canvas,
    String myUserId,
    AuthState authState,
  ) {
    final participants = _gatherParticipants(myUserId, authState);
    final anyoneSpeaking = participants.any((p) => p.isSpeaking);
    final size = _canvasSize();
    final widgets = <Widget>[];

    for (int i = 0; i < participants.length; i++) {
      final participant = participants[i];
      widgets.add(
        _buildAvatarWidget(
          canvas,
          participant,
          i,
          participants.length,
          size,
          anyoneSpeaking,
          authState,
        ),
      );
    }

    return widgets;
  }

  List<_ParticipantInfo> _gatherParticipants(
    String myUserId,
    AuthState authState,
  ) {
    final participants = <_ParticipantInfo>[];
    final room = widget.room;
    final voiceState = widget.voiceState;

    // Add local participant
    final localName = authState.username ?? 'You';
    lk.VideoTrack? localVideoTrack;
    if (room != null && voiceState.isVideoEnabled) {
      final pub = room.localParticipant?.videoTrackPublications
          .where((p) => p.track != null && p.source == lk.TrackSource.camera)
          .firstOrNull;
      localVideoTrack = pub?.track as lk.VideoTrack?;
    }
    participants.add(
      _ParticipantInfo(
        userId: myUserId,
        name: localName,
        avatarUrl: widget.localAvatarUrl,
        audioLevel: voiceState.localAudioLevel,
        isLocal: true,
        videoTrack: localVideoTrack,
        mirror: true,
      ),
    );

    // Add remote participants
    if (room != null) {
      for (final p in room.remoteParticipants.values) {
        final uid = p.identity;
        final level = voiceState.peerAudioLevels[uid] ?? 0.0;
        final remotePub = p.videoTrackPublications
            .where(
              (pub) =>
                  pub.track != null &&
                  pub.track is lk.VideoTrack &&
                  pub.source == lk.TrackSource.camera,
            )
            .firstOrNull;
        final remoteVideo = remotePub?.track as lk.VideoTrack?;
        participants.add(
          _ParticipantInfo(
            userId: uid,
            name: participantDisplayName(p),
            avatarUrl: null,
            audioLevel: level,
            isLocal: false,
            videoTrack: remoteVideo,
          ),
        );
      }
    }

    return participants;
  }

  Widget _buildAvatarWidget(
    CanvasState canvas,
    _ParticipantInfo participant,
    int index,
    int totalParticipants,
    Size canvasSize,
    bool anyoneSpeaking,
    AuthState authState,
  ) {
    final pos = canvas.avatarPositions[participant.userId];
    final defaultPos = _defaultAvatarPos(
      participant.userId,
      totalParticipants,
      index,
    );
    final normalized = pos ?? defaultPos;
    final offset = _toLocal(CanvasPoint(x: normalized.x, y: normalized.y));

    final left = (offset.dx - _kAvatarHalfSize).clamp(
      0.0,
      canvasSize.width > _kAvatarSize ? canvasSize.width - _kAvatarSize : 0.0,
    );
    final top = (offset.dy - _kAvatarHalfSize).clamp(
      0.0,
      canvasSize.height > _kAvatarSize ? canvasSize.height - _kAvatarSize : 0.0,
    );

    final attention = attentionFor(
      isSpeaking: participant.isSpeaking,
      anyoneElseSpeaking: anyoneSpeaking && !participant.isSpeaking,
    );

    return Positioned(
      left: left,
      top: top,
      child: _DraggableAvatar(
        key: ValueKey('avatar-${participant.userId}'),
        participant: participant,
        canvasSize: canvasSize,
        currentPos: CanvasPoint(x: normalized.x, y: normalized.y),
        attention: attention,
        httpHeaders: authState.token != null
            ? {'Authorization': 'Bearer ${authState.token}'}
            : null,
        onDrag: (norm) {
          ref
              .read(canvasProvider.notifier)
              .moveLocalAvatar(participant.userId, norm);
        },
        onDragEnd: (norm) {
          ref
              .read(canvasProvider.notifier)
              .commitLocalAvatarMove(participant.userId, norm);
        },
        draggable: true,
        onDoubleTap: participant.videoTrack != null
            ? () => widget.onVideoDoubleTap?.call(
                participant.videoTrack!,
                participant.mirror,
              )
            : null,
      ),
    );
  }

  AvatarPosition _defaultAvatarPos(String userId, int total, int index) {
    if (total <= 1) return AvatarPosition(userId: userId, x: 0.5, y: 0.5);
    final angle = (2 * math.pi * index) / total;
    const r = 0.3;
    return AvatarPosition(
      userId: userId,
      x: 0.5 + r * math.cos(angle),
      y: 0.5 + r * math.sin(angle),
    );
  }

  List<Widget> _buildImages(CanvasState canvas, AuthState authState) {
    final size = _canvasSize();
    final token = authState.token;
    final httpHeaders = token != null
        ? <String, String>{'Authorization': 'Bearer $token'}
        : null;
    return canvas.images.map((img) {
      final x = img.x * size.width;
      final y = img.y * size.height;
      final w = img.width * size.width;
      final h = img.height * size.height;

      return Positioned(
        left: x,
        top: y,
        width: w,
        height: h,
        child: _CanvasImageWidget(
          image: img,
          httpHeaders: httpHeaders,
          onMove: (dx, dy) {
            final current = ref
                .read(canvasProvider)
                .images
                .where((i) => i.id == img.id)
                .firstOrNull;
            final curX = (current?.x ?? img.x) * size.width;
            final curY = (current?.y ?? img.y) * size.height;
            final newX = ((curX + dx) / size.width).clamp(0.0, 1.0);
            final newY = ((curY + dy) / size.height).clamp(0.0, 1.0);
            ref.read(canvasProvider.notifier).moveImage(img.id, newX, newY);
          },
          onMoveEnd: () {
            final currentImg = ref
                .read(canvasProvider)
                .images
                .where((i) => i.id == img.id)
                .firstOrNull;
            if (currentImg != null) {
              ref
                  .read(canvasProvider.notifier)
                  .commitImageMove(img.id, currentImg.x, currentImg.y);
            }
          },
          onResize: (dx, dy) {
            final current = ref
                .read(canvasProvider)
                .images
                .where((i) => i.id == img.id)
                .firstOrNull;
            final curW = (current?.width ?? img.width) * size.width;
            final curH = (current?.height ?? img.height) * size.height;
            final newW = ((curW + dx) / size.width).clamp(0.05, 1.0);
            final newH = ((curH + dy) / size.height).clamp(0.05, 1.0);
            ref.read(canvasProvider.notifier).resizeImage(img.id, newW, newH);
          },
          onResizeEnd: () =>
              ref.read(canvasProvider.notifier).commitImageResize(img.id),
          onRemove: () => ref.read(canvasProvider.notifier).removeImage(img.id),
        ),
      );
    }).toList();
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      final isCtrl =
          HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyV) {
        _handlePasteImage();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Future<void> _handlePasteImage() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.startsWith('http://') || text.startsWith('https://')) {
        _addImageFromUrl(text);
        return;
      }
    } catch (e) {
      debugPrint('Canvas: clipboard read failed: $e');
    }
  }

  void _addImageFromUrl(String url) {
    final rng = math.Random();
    final img = CanvasImage(
      id: newCanvasId(),
      url: url,
      x: 0.2 + rng.nextDouble() * 0.3,
      y: 0.2 + rng.nextDouble() * 0.3,
      width: 0.25,
      height: 0.25,
    );
    ref.read(canvasProvider.notifier).addImage(img);
  }
}

class _DrawingLayer extends StatelessWidget {
  final CanvasState canvas;
  final void Function(Offset) onPointerDown;
  final void Function(Offset) onPointerMove;
  final VoidCallback onPointerUp;

  const _DrawingLayer({
    required this.canvas,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
  });

  @override
  Widget build(BuildContext context) {
    final behavior = canvas.selectedTool == CanvasTool.none
        ? HitTestBehavior.deferToChild
        : HitTestBehavior.translucent;
    return Listener(
      behavior: behavior,
      onPointerDown: (e) {
        if (e.buttons != kPrimaryButton) return;
        onPointerDown(e.localPosition);
      },
      onPointerMove: (e) {
        if (e.buttons != kPrimaryButton) return;
        onPointerMove(e.localPosition);
      },
      onPointerUp: (_) => onPointerUp(),
      onPointerCancel: (_) => onPointerUp(),
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _CanvasPainter(canvas: canvas),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _CanvasPainter extends CustomPainter {
  final CanvasState canvas;

  const _CanvasPainter({required this.canvas});

  bool _hasEraserStrokes() {
    for (final s in canvas.strokes) {
      if (s.kind == StrokeKind.eraser) return true;
    }
    if (canvas.activePoints.isNotEmpty &&
        canvas.selectedTool == CanvasTool.eraser) {
      return true;
    }
    return false;
  }

  @override
  void paint(Canvas c, Size size) {
    // saveLayer needed only for eraser BlendMode.clear; skip otherwise — offscreen buffer is heavy on CanvasKit.
    final needsLayer = _hasEraserStrokes();
    if (needsLayer) c.saveLayer(Offset.zero & size, Paint());

    for (final stroke in canvas.strokes) {
      _paintStroke(c, size, stroke);
    }

    if (canvas.activePoints.isNotEmpty) {
      final tool = canvas.selectedTool;
      final isEraser = tool == CanvasTool.eraser;
      final activeStroke = CanvasStroke(
        id: '__active__',
        color: isEraser ? '#000000' : colorToHex(canvas.currentColor),
        width: isEraser ? canvas.strokeWidth * 3 : canvas.strokeWidth,
        points: canvas.activePoints,
        kind: isEraser ? StrokeKind.eraser : StrokeKind.pen,
      );
      _paintStroke(c, size, activeStroke);
    }

    if (needsLayer) c.restore();
  }

  void _paintStroke(Canvas c, Size size, CanvasStroke stroke) {
    if (stroke.points.isEmpty) return;

    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke.width;

    if (stroke.kind == StrokeKind.eraser) {
      paint
        ..blendMode = BlendMode.clear
        ..color = const Color(0x00000000);
    } else {
      paint
        ..blendMode = BlendMode.srcOver
        ..color = _parseColor(stroke.color);
    }

    final first = stroke.points.first;

    if (stroke.points.length == 1) {
      c.drawCircle(
        Offset(first.x * size.width, first.y * size.height),
        stroke.width / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }

    final path = Path();
    path.moveTo(first.x * size.width, first.y * size.height);
    for (int i = 1; i < stroke.points.length; i++) {
      final p = stroke.points[i];
      path.lineTo(p.x * size.width, p.y * size.height);
    }

    c.drawPath(path, paint..style = PaintingStyle.stroke);
  }

  static Color _parseColor(String hex) {
    final s = hex.replaceFirst('#', '');
    if (s.length == 8) {
      return Color(int.parse(s, radix: 16));
    }
    if (s.length == 6) {
      return Color(0xFF000000 | int.parse(s, radix: 16));
    }
    return EchoTheme.textPrimary;
  }

  @override
  bool shouldRepaint(_CanvasPainter old) {
    // Provider may hand back fresh List each tick; compare lengths + last stroke id.
    if (old.canvas.strokes.length != canvas.strokes.length) return true;
    if (old.canvas.activePoints.length != canvas.activePoints.length) {
      return true;
    }
    if (canvas.strokes.isNotEmpty &&
        canvas.strokes.last.id != old.canvas.strokes.last.id) {
      return true;
    }
    return false;
  }
}

class _ParticipantInfo {
  final String userId;
  final String name;
  final String? avatarUrl;
  final double audioLevel;
  final bool isLocal;
  final lk.VideoTrack? videoTrack;
  final bool mirror;

  bool get isSpeaking => audioLevel > 0.05;

  const _ParticipantInfo({
    required this.userId,
    required this.name,
    required this.avatarUrl,
    required this.audioLevel,
    required this.isLocal,
    this.videoTrack,
    this.mirror = false,
  });
}

class _DraggableAvatar extends StatefulWidget {
  final _ParticipantInfo participant;
  final Size canvasSize;

  /// Current normalized position [0,1] on the canvas.
  final CanvasPoint currentPos;
  final void Function(CanvasPoint norm) onDrag;
  final void Function(CanvasPoint norm) onDragEnd;
  final bool draggable;
  final VoidCallback? onDoubleTap;

  /// Phase 3c: room-level attention (speaking / faded / idle).  Drives
  /// the avatar's scale + opacity so non-speakers fade back when
  /// someone else is on the air.
  final ParticipantAttention attention;

  final Map<String, String>? httpHeaders;

  const _DraggableAvatar({
    super.key,
    required this.participant,
    required this.canvasSize,
    required this.currentPos,
    required this.onDrag,
    required this.onDragEnd,
    this.attention = ParticipantAttention.idle,
    this.draggable = false,
    this.onDoubleTap,
    this.httpHeaders,
  });

  @override
  State<_DraggableAvatar> createState() => _DraggableAvatarState();
}

class _DraggableAvatarState extends State<_DraggableAvatar>
    with SingleTickerProviderStateMixin {
  CanvasPoint? _localPos;

  /// Buffer of recent positions used to paint the presence trail
  /// (Phase 3a sub-slice 2 of `docs/ux-roadmap.md`).
  final PuckTrail _trail = PuckTrail();

  /// Drives a 60Hz repaint of the trail so old samples fade smoothly.
  /// Only ticks while the buffer holds at least one sample.
  late final Ticker _trailTicker;

  /// Tick counter the trail's CustomPainter watches via `repaint:`. Bumping
  /// this triggers a scoped repaint of just the _TrailPainter — without
  /// rebuilding the rest of the avatar (video tile, opacity/scale animators,
  /// etc.) on every Ticker frame. Previously the Ticker called
  /// `setState({})` 60 Hz per participant, rebuilding the whole subtree.
  final ValueNotifier<int> _trailTick = ValueNotifier<int>(0);

  /// Cached reduce-motion value; refreshed on `didChangeDependencies`
  /// and `didUpdateWidget` so we don't sample inside `MediaQuery.of`
  /// during paint.
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _trailTicker = createTicker(_onTrailTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_reduceMotion) _stopTrail();
  }

  @override
  void didUpdateWidget(_DraggableAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final prev = oldWidget.currentPos;
    final next = widget.currentPos;
    if (!_reduceMotion && (prev.x != next.x || prev.y != next.y)) {
      // Remote (or post-drag committed) position arrived — record the
      // *previous* point so the trail starts where the puck just was.
      _pushTrailSample(prev);
    }
  }

  @override
  void dispose() {
    _trailTicker.dispose();
    _trailTick.dispose();
    _trail.clear();
    super.dispose();
  }

  void _pushTrailSample(CanvasPoint pos) {
    if (_reduceMotion) return;
    _trail.addSample(pos, DateTime.now());
    if (!_trailTicker.isActive) _trailTicker.start();
  }

  void _stopTrail() {
    if (_trailTicker.isActive) _trailTicker.stop();
    _trail.clear();
  }

  void _onTrailTick(Duration _) {
    final now = DateTime.now();
    _trail.prune(now);
    if (_trail.isEmpty) {
      _trailTicker.stop();
    }
    // Bump notifier (CustomPainter `repaint:`) so only the trail layer repaints, not the avatar subtree.
    if (mounted) _trailTick.value = _trailTick.value + 1;
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.participant;
    final initial = info.name.isNotEmpty ? info.name[0].toUpperCase() : '?';
    final scales = _computeAttentionScales();
    final hasVideo = info.videoTrack != null;
    final innerContent = _buildInnerContent(info, initial);
    final tile = _buildAvatarTile(info, innerContent, hasVideo);
    final avatar = _buildAnimatedAvatar(info, tile, scales);
    final avatarWithTrail = _buildAvatarWithTrail(avatar);
    final content = _buildContent(info, avatarWithTrail);

    if (!widget.draggable) return content;

    return _buildDraggableWrapper(content);
  }

  ({double scale, double opacity}) _computeAttentionScales() {
    if (_reduceMotion) {
      return (scale: 1.0, opacity: 1.0);
    }
    return switch (widget.attention) {
      ParticipantAttention.speaking => (scale: 1.16, opacity: 1.0),
      ParticipantAttention.faded => (scale: 0.92, opacity: 0.62),
      ParticipantAttention.idle => (scale: 1.0, opacity: 1.0),
    };
  }

  Widget _buildInnerContent(_ParticipantInfo info, String initial) {
    final hasVideo = info.videoTrack != null;
    if (hasVideo) {
      return lk.VideoTrackRenderer(
        info.videoTrack!,
        fit: lk.VideoViewFit.cover,
        mirrorMode: info.mirror
            ? lk.VideoViewMirrorMode.mirror
            : lk.VideoViewMirrorMode.off,
      );
    }
    if (info.avatarUrl != null) {
      return CachedNetworkImage(
        imageUrl: info.avatarUrl!,
        httpHeaders: widget.httpHeaders,
        fit: BoxFit.cover,
        placeholder: (_, _) => _initialsWidget(initial),
        errorWidget: (_, _, _) => _initialsWidget(initial),
      );
    }
    return _initialsWidget(initial);
  }

  Widget _buildAvatarTile(
    _ParticipantInfo info,
    Widget innerContent,
    bool hasVideo,
  ) {
    final hue = (info.userId.hashCode % 360).abs().toDouble();
    final avatarColor = HSLColor.fromAHSL(1.0, hue, 0.5, 0.35).toColor();

    return Container(
      width: _kAvatarSize,
      height: _kAvatarSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: hasVideo
            ? context.chatBg
            : context.chatBg.withValues(alpha: 0.45),
      ),
      clipBehavior: Clip.antiAlias,
      child: hasVideo
          ? innerContent
          : Stack(
              fit: StackFit.expand,
              children: [
                Container(color: avatarColor.withValues(alpha: 0.55)),
                innerContent,
              ],
            ),
    );
  }

  Widget _buildAnimatedAvatar(
    _ParticipantInfo info,
    Widget tile,
    ({double scale, double opacity}) scales,
  ) {
    return AnimatedOpacity(
      opacity: scales.opacity,
      duration: MotionDurations.standard,
      curve: MotionCurves.entrance,
      child: AnimatedScale(
        scale: scales.scale,
        duration: MotionDurations.quick,
        curve: MotionCurves.emphasis,
        child: VoiceSpeakingRing(
          audioLevel: info.audioLevel,
          child: Container(
            width: _kAvatarSize,
            height: _kAvatarSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: context.mainBg.withValues(alpha: 0.35),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: tile,
          ),
        ),
      ),
    );
  }

  Widget _buildAvatarWithTrail(Widget avatar) {
    if (_reduceMotion) return avatar;

    // Keep trail layer mounted (idle painter returns early) to avoid CustomPaint remount when buffer flips empty/non-empty.
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              size: const Size(_kAvatarSize, _kAvatarSize),
              painter: _TrailPainter(
                trail: _trail,
                currentPos: _localPos ?? widget.currentPos,
                canvasSize: widget.canvasSize,
                color: EchoTheme.online,
                radius: _kAvatarHalfSize * 0.45,
                tick: _trailTick,
              ),
            ),
          ),
        ),
        avatar,
      ],
    );
  }

  Widget _buildContent(_ParticipantInfo info, Widget avatarWithTrail) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        avatarWithTrail,
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: context.surface.withValues(alpha: 0.54),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            info.name,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildDraggableWrapper(Widget content) {
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onDoubleTap: widget.onDoubleTap,
        onPanUpdate: (details) {
          final s = widget.canvasSize;
          if (s.width <= 0 || s.height <= 0) return;
          final dx = details.delta.dx / s.width;
          final dy = details.delta.dy / s.height;
          final base = _localPos ?? widget.currentPos;
          final newPos = CanvasPoint(
            x: (base.x + dx).clamp(0.0, 1.0),
            y: (base.y + dy).clamp(0.0, 1.0),
          );
          _pushTrailSample(base);
          _localPos = newPos;
          widget.onDrag(newPos);
        },
        onPanEnd: (_) {
          widget.onDragEnd(_localPos ?? widget.currentPos);
          _localPos = null;
        },
        child: content,
      ),
    );
  }

  Widget _initialsWidget(String initial) => Center(
    child: Text(
      initial,
      style: TextStyle(
        color: context.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

/// Returns true when a URL points at an animated GIF asset. We only check
/// the path's extension because the server already vets MIME type on
/// upload and query strings on .gif (CDN cache busters) are common.
bool _isGif(String url) {
  final lower = url.split('?').first.toLowerCase();
  return lower.endsWith('.gif');
}

class _CanvasImageWidget extends StatefulWidget {
  final CanvasImage image;
  final Map<String, String>? httpHeaders;
  final void Function(double dx, double dy) onMove;
  final VoidCallback onMoveEnd;
  final void Function(double dx, double dy) onResize;
  final VoidCallback onResizeEnd;
  final VoidCallback onRemove;

  const _CanvasImageWidget({
    required this.image,
    this.httpHeaders,
    required this.onMove,
    required this.onMoveEnd,
    required this.onResize,
    required this.onResizeEnd,
    required this.onRemove,
  });

  @override
  State<_CanvasImageWidget> createState() => _CanvasImageWidgetState();
}

class _CanvasImageWidgetState extends State<_CanvasImageWidget> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onPanUpdate: (d) => widget.onMove(d.delta.dx, d.delta.dy),
        onPanEnd: (_) => widget.onMoveEnd(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                boxShadow: [
                  BoxShadow(
                    color: context.mainBg.withValues(alpha: 0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                // GIFs need Image.network for multi-frame animation;
                // CachedNetworkImage decodes a single frame so animated
                // GIFs render as a static first frame. Detect the .gif
                // extension and pick the right widget per image.
                child: _isGif(widget.image.url)
                    ? Image.network(
                        widget.image.url,
                        headers: widget.httpHeaders ?? const {},
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => Container(
                          color: context.surfaceHover,
                          child: Icon(
                            Icons.broken_image,
                            color: context.textMuted,
                          ),
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: widget.image.url,
                        httpHeaders: widget.httpHeaders ?? const {},
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => Container(
                          color: context.surfaceHover,
                          child: Icon(
                            Icons.broken_image,
                            color: context.textMuted,
                          ),
                        ),
                      ),
              ),
            ),
            if (_hovered)
              Positioned(
                top: 4,
                right: 4,
                child: GestureDetector(
                  onTap: widget.onRemove,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: context.surface.withValues(alpha: 0.54),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: context.textPrimary,
                    ),
                  ),
                ),
              ),
            if (_hovered)
              Positioned(
                bottom: 0,
                right: 0,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeDownRight,
                  child: GestureDetector(
                    onPanUpdate: (d) => widget.onResize(d.delta.dx, d.delta.dy),
                    onPanEnd: (_) => widget.onResizeEnd(),
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: context.surface.withValues(alpha: 0.7),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(8),
                          bottomRight: Radius.circular(4),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.open_in_full,
                        size: 14,
                        color: context.textPrimary,
                      ),
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

/// Paints fading ghost circles at past positions of a puck so motion
/// reads as "presence" rather than a snapping cursor.
///
/// Phase 3a sub-slice 2 of `docs/ux-roadmap.md`. Samples are computed
/// inside paint() from the live [PuckTrail] so the parent doesn't have
/// to rebuild on every Ticker frame just to pass a fresh sample list.
/// Repaint is driven by [repaint] (the per-avatar tick notifier).
class _TrailPainter extends CustomPainter {
  final PuckTrail trail;
  final CanvasPoint currentPos;
  final Size canvasSize;
  final Color color;

  /// Radius of each ghost circle.  Smaller than the puck itself so
  /// trails read as a wake, not a doppelgänger.
  final double radius;

  _TrailPainter({
    required this.trail,
    required this.currentPos,
    required this.canvasSize,
    required this.color,
    required this.radius,
    required Listenable tick,
  }) : super(repaint: tick);

  @override
  void paint(Canvas canvas, Size size) {
    if (trail.isEmpty) return;
    final samples = trail.render(
      current: currentPos,
      canvasSize: canvasSize,
      now: DateTime.now(),
    );
    if (samples.isEmpty) return;
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()..style = PaintingStyle.fill;
    for (final s in samples) {
      // Trails are subdued — multiply by 0.45 so the puck stays the
      // visual anchor and the wake stays in the periphery.
      final alpha = (s.opacity * 0.45).clamp(0.0, 1.0);
      if (alpha < 0.04) continue;
      paint.color = color.withValues(alpha: alpha);
      canvas.drawCircle(center + s.offset, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TrailPainter old) =>
      // The repaint Listenable drives ticks; only structural changes need
      // shouldRepaint to fire (canvas resize, position handoff).
      !identical(old.trail, trail) ||
      old.canvasSize != canvasSize ||
      old.currentPos.x != currentPos.x ||
      old.currentPos.y != currentPos.y ||
      old.color != color ||
      old.radius != radius;
}
