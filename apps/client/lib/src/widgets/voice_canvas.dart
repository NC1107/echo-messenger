import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../models/canvas_models.dart';
import '../providers/auth_provider.dart';
import '../providers/canvas_provider.dart';
import '../providers/livekit_voice_provider.dart';
import '../theme/echo_theme.dart';
import '../utils/canvas_utils.dart';
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
    final widgets = <Widget>[];
    final room = widget.room;
    final voiceState = widget.voiceState;
    final size = _canvasSize();

    final participants = <_ParticipantInfo>[];

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

    for (int i = 0; i < participants.length; i++) {
      final participant = participants[i];
      final pos = canvas.avatarPositions[participant.userId];

      final defaultPos = _defaultAvatarPos(
        participant.userId,
        participants.length,
        i,
      );

      final normalized = pos ?? defaultPos;
      final offset = _toLocal(CanvasPoint(x: normalized.x, y: normalized.y));

      final left = (offset.dx - _kAvatarHalfSize).clamp(
        0.0,
        size.width > _kAvatarSize ? size.width - _kAvatarSize : 0.0,
      );
      final top = (offset.dy - _kAvatarHalfSize).clamp(
        0.0,
        size.height > _kAvatarSize ? size.height - _kAvatarSize : 0.0,
      );

      widgets.add(
        Positioned(
          left: left,
          top: top,
          child: _DraggableAvatar(
            key: ValueKey('avatar-${participant.userId}'),
            participant: participant,
            canvasSize: size,
            currentPos: CanvasPoint(x: normalized.x, y: normalized.y),
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
        ),
      );
    }

    return widgets;
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

  @override
  void paint(Canvas c, Size size) {
    c.saveLayer(Offset.zero & size, Paint());

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

    c.restore();
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
  bool shouldRepaint(_CanvasPainter old) =>
      old.canvas.strokes != canvas.strokes ||
      old.canvas.activePoints != canvas.activePoints;
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

  final Map<String, String>? httpHeaders;

  const _DraggableAvatar({
    super.key,
    required this.participant,
    required this.canvasSize,
    required this.currentPos,
    required this.onDrag,
    required this.onDragEnd,
    this.draggable = false,
    this.onDoubleTap,
    this.httpHeaders,
  });

  @override
  State<_DraggableAvatar> createState() => _DraggableAvatarState();
}

class _DraggableAvatarState extends State<_DraggableAvatar> {
  CanvasPoint? _localPos;

  @override
  Widget build(BuildContext context) {
    final info = widget.participant;
    final hue = (info.userId.hashCode % 360).abs().toDouble();
    final avatarColor = HSLColor.fromAHSL(1.0, hue, 0.5, 0.35).toColor();
    final initial = info.name.isNotEmpty ? info.name[0].toUpperCase() : '?';

    final scale = info.isSpeaking ? 1.12 : 1.0;

    final hasVideo = info.videoTrack != null;

    final innerContent = hasVideo
        ? lk.VideoTrackRenderer(
            info.videoTrack!,
            fit: lk.VideoViewFit.cover,
            mirrorMode: info.mirror
                ? lk.VideoViewMirrorMode.mirror
                : lk.VideoViewMirrorMode.off,
          )
        : info.avatarUrl != null
        ? CachedNetworkImage(
            imageUrl: info.avatarUrl!,
            httpHeaders: widget.httpHeaders,
            fit: BoxFit.cover,
            placeholder: (_, _) => _initialsWidget(initial),
            errorWidget: (_, _, _) => _initialsWidget(initial),
          )
        : _initialsWidget(initial);

    final tile = Container(
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

    final avatar = AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 150),
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
    );

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        avatar,
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

    if (!widget.draggable) return content;

    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: GestureDetector(
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

class _CanvasImageWidget extends StatefulWidget {
  final CanvasImage image;
  final Map<String, String>? httpHeaders;
  final void Function(double dx, double dy) onMove;
  final VoidCallback onMoveEnd;
  final VoidCallback onRemove;

  const _CanvasImageWidget({
    required this.image,
    this.httpHeaders,
    required this.onMove,
    required this.onMoveEnd,
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
                child: CachedNetworkImage(
                  imageUrl: widget.image.url,
                  httpHeaders: widget.httpHeaders ?? const {},
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => Container(
                    color: context.surfaceHover,
                    child: Icon(Icons.broken_image, color: context.textMuted),
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
          ],
        ),
      ),
    );
  }
}
