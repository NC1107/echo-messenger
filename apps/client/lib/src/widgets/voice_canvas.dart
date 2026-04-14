import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
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

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const double _kAvatarSize = 72.0;
const double _kAvatarHalfSize = _kAvatarSize / 2;
const double _kToolbarHeight = 56.0;

// ---------------------------------------------------------------------------
// VoiceCanvas
// ---------------------------------------------------------------------------

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

  const VoiceCanvas({
    super.key,
    required this.channelId,
    required this.conversationId,
    required this.voiceState,
    this.room,
    this.localAvatarUrl,
  });

  @override
  ConsumerState<VoiceCanvas> createState() => _VoiceCanvasState();
}

class _VoiceCanvasState extends ConsumerState<VoiceCanvas> {
  final _canvasKey = GlobalKey();

  // Clipboard paste listener
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
    ref.read(canvasProvider.notifier).detach();
    _focusNode.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Coordinate helpers
  // -------------------------------------------------------------------------

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

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final canvas = ref.watch(canvasProvider);
    final myUserId = ref.read(authProvider).userId ?? '';
    final tool = canvas.selectedTool;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) => _handleKeyEvent(event),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Paste shortcut handled via keyboard, clipboard handled via toolbar
        child: Column(
          children: [
            // Canvas area
            Expanded(
              child: ClipRect(
                child: Stack(
                  key: _canvasKey,
                  children: [
                    // 1. Drawing layer (CustomPaint + gesture input)
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

                    // 2. Images layer
                    ..._buildImages(canvas),

                    // 3. Avatars layer
                    ..._buildAvatars(canvas, myUserId),
                  ],
                ),
              ),
            ),

            // Toolbar
            _CanvasToolbar(
              canvas: canvas,
              onSetTool: (t) => ref.read(canvasProvider.notifier).setTool(t),
              onSetColor: (c) => ref.read(canvasProvider.notifier).setColor(c),
              onSetWidth: (w) =>
                  ref.read(canvasProvider.notifier).setStrokeWidth(w),
              onClear: () => ref.read(canvasProvider.notifier).clearDrawing(),
              onPasteImage: _handlePasteImage,
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Avatar widgets
  // -------------------------------------------------------------------------

  List<Widget> _buildAvatars(CanvasState canvas, String myUserId) {
    final widgets = <Widget>[];
    final room = widget.room;
    final voiceState = widget.voiceState;
    final size = _canvasSize();

    // Collect all participants
    final participants = <_ParticipantInfo>[];

    // Local user
    final localName = ref.read(authProvider).username ?? 'You';
    participants.add(
      _ParticipantInfo(
        userId: myUserId,
        name: localName,
        avatarUrl: widget.localAvatarUrl,
        isSpeaking: voiceState.localAudioLevel > 0.05,
        isLocal: true,
      ),
    );

    // Remote participants from LiveKit room
    if (room != null) {
      for (final p in room.remoteParticipants.values) {
        final uid = p.identity;
        final level = voiceState.peerAudioLevels[uid] ?? 0.0;
        participants.add(
          _ParticipantInfo(
            userId: uid,
            name: participantDisplayName(p),
            avatarUrl: null,
            isSpeaking: level > 0.05,
            isLocal: false,
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
            draggable: participant.isLocal,
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

  // -------------------------------------------------------------------------
  // Image widgets
  // -------------------------------------------------------------------------

  List<Widget> _buildImages(CanvasState canvas) {
    final size = _canvasSize();
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
          onMove: (dx, dy) {
            final newX = ((x + dx) / size.width).clamp(0.0, 1.0);
            final newY = ((y + dy) / size.height).clamp(0.0, 1.0);
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

  // -------------------------------------------------------------------------
  // Keyboard / clipboard
  // -------------------------------------------------------------------------

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
      // If clipboard text looks like a URL, add it as an image
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
    // Place image near center with some randomness
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

// ---------------------------------------------------------------------------
// Drawing layer
// ---------------------------------------------------------------------------

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
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => onPointerDown(e.localPosition),
      onPointerMove: (e) => onPointerMove(e.localPosition),
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

// ---------------------------------------------------------------------------
// CustomPainter
// ---------------------------------------------------------------------------

class _CanvasPainter extends CustomPainter {
  final CanvasState canvas;

  const _CanvasPainter({required this.canvas});

  @override
  void paint(Canvas c, Size size) {
    // Wrap everything in a single saveLayer so eraser BlendMode.clear
    // can erase pixels drawn by earlier pen strokes in the same layer.
    c.saveLayer(Offset.zero & size, Paint());

    for (final stroke in canvas.strokes) {
      _paintStroke(c, size, stroke);
    }

    if (canvas.activePoints.length >= 2) {
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
    if (stroke.points.length < 2) return;

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

    final path = Path();
    final first = stroke.points.first;
    path.moveTo(first.x * size.width, first.y * size.height);
    for (int i = 1; i < stroke.points.length; i++) {
      final p = stroke.points[i];
      path.lineTo(p.x * size.width, p.y * size.height);
    }

    c.drawPath(path, paint);
  }

  static Color _parseColor(String hex) {
    final s = hex.replaceFirst('#', '');
    if (s.length == 8) {
      return Color(int.parse(s, radix: 16));
    }
    if (s.length == 6) {
      return Color(0xFF000000 | int.parse(s, radix: 16));
    }
    return Colors.white;
  }

  @override
  bool shouldRepaint(_CanvasPainter old) =>
      old.canvas.strokes != canvas.strokes ||
      old.canvas.activePoints != canvas.activePoints;
}

// ---------------------------------------------------------------------------
// Draggable avatar
// ---------------------------------------------------------------------------

class _ParticipantInfo {
  final String userId;
  final String name;
  final String? avatarUrl;
  final bool isSpeaking;
  final bool isLocal;

  const _ParticipantInfo({
    required this.userId,
    required this.name,
    required this.avatarUrl,
    required this.isSpeaking,
    required this.isLocal,
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

  const _DraggableAvatar({
    super.key,
    required this.participant,
    required this.canvasSize,
    required this.currentPos,
    required this.onDrag,
    required this.onDragEnd,
    this.draggable = false,
  });

  @override
  State<_DraggableAvatar> createState() => _DraggableAvatarState();
}

class _DraggableAvatarState extends State<_DraggableAvatar> {
  @override
  Widget build(BuildContext context) {
    final info = widget.participant;
    final hue = (info.userId.hashCode % 360).abs().toDouble();
    final avatarColor = HSLColor.fromAHSL(1.0, hue, 0.5, 0.35).toColor();
    final initial = info.name.isNotEmpty ? info.name[0].toUpperCase() : '?';

    final speakRingColor = info.isSpeaking
        ? EchoTheme.online
        : Colors.transparent;
    final ringWidth = info.isSpeaking ? 3.5 : 2.0;
    final scale = info.isSpeaking ? 1.12 : 1.0;

    Widget avatar = AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 150),
      child: Container(
        width: _kAvatarSize,
        height: _kAvatarSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: avatarColor,
          border: Border.all(color: speakRingColor, width: ringWidth),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: info.avatarUrl != null
            ? CachedNetworkImage(
                imageUrl: info.avatarUrl!,
                fit: BoxFit.cover,
                placeholder: (_, _) => _initialsWidget(initial),
                errorWidget: (_, _, _) => _initialsWidget(initial),
              )
            : _initialsWidget(initial),
      ),
    );

    // Username label below avatar
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        avatar,
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            info.name,
            style: const TextStyle(
              color: Colors.white,
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
        onPanUpdate: (details) {
          final s = widget.canvasSize;
          if (s.width <= 0 || s.height <= 0) return;
          final dx = details.delta.dx / s.width;
          final dy = details.delta.dy / s.height;
          final newPos = CanvasPoint(
            x: (widget.currentPos.x + dx).clamp(0.0, 1.0),
            y: (widget.currentPos.y + dy).clamp(0.0, 1.0),
          );
          widget.onDrag(newPos);
        },
        onPanEnd: (_) {
          widget.onDragEnd(widget.currentPos);
        },
        child: content,
      ),
    );
  }

  Widget _initialsWidget(String initial) => Center(
    child: Text(
      initial,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 26,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Canvas image widget
// ---------------------------------------------------------------------------

class _CanvasImageWidget extends StatefulWidget {
  final CanvasImage image;
  final void Function(double dx, double dy) onMove;
  final VoidCallback onMoveEnd;
  final VoidCallback onRemove;

  const _CanvasImageWidget({
    required this.image,
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
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: CachedNetworkImage(
                  imageUrl: widget.image.url,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => Container(
                    color: Colors.grey[800],
                    child: const Icon(
                      Icons.broken_image,
                      color: Colors.white54,
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
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      size: 14,
                      color: Colors.white,
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

// ---------------------------------------------------------------------------
// Toolbar
// ---------------------------------------------------------------------------

class _CanvasToolbar extends StatelessWidget {
  final CanvasState canvas;
  final void Function(CanvasTool) onSetTool;
  final void Function(Color) onSetColor;
  final void Function(double) onSetWidth;
  final VoidCallback onClear;
  final VoidCallback onPasteImage;

  const _CanvasToolbar({
    required this.canvas,
    required this.onSetTool,
    required this.onSetColor,
    required this.onSetWidth,
    required this.onClear,
    required this.onPasteImage,
  });

  static const _colors = [
    Color(0xFFFFFFFF),
    Color(0xFFFF453A),
    Color(0xFFFF9F0A),
    Color(0xFFFFD60A),
    Color(0xFF32D74B),
    Color(0xFF0A84FF),
    Color(0xFFBF5AF2),
    Color(0xFFFF375F),
    Color(0xFF000000),
  ];

  @override
  Widget build(BuildContext context) {
    final isPen = canvas.selectedTool == CanvasTool.pen;
    final isEraser = canvas.selectedTool == CanvasTool.eraser;

    return Container(
      height: _kToolbarHeight,
      color: context.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          // Pen
          _ToolButton(
            icon: Icons.edit,
            active: isPen,
            tooltip: 'Pen',
            onTap: () => onSetTool(CanvasTool.pen),
          ),
          const SizedBox(width: 4),
          // Eraser
          _ToolButton(
            icon: Icons.cleaning_services,
            active: isEraser,
            tooltip: 'Eraser',
            onTap: () => onSetTool(CanvasTool.eraser),
          ),
          const SizedBox(width: 8),
          // Color swatches (only shown when pen is active)
          if (isPen)
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _colors.map((c) {
                    final selected =
                        canvas.currentColor.toARGB32() == c.toARGB32();
                    return GestureDetector(
                      onTap: () => onSetColor(c),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: selected ? 26 : 22,
                        height: selected ? 26 : 22,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: c,
                          border: Border.all(
                            color: selected ? EchoTheme.accent : Colors.white24,
                            width: selected ? 2.5 : 1.5,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            )
          else
            const Spacer(),
          const SizedBox(width: 8),
          // Stroke width slider (pen mode only)
          if (isPen)
            SizedBox(
              width: 90,
              child: Slider(
                value: canvas.strokeWidth,
                min: 1.0,
                max: 20.0,
                onChanged: onSetWidth,
                activeColor: EchoTheme.accent,
              ),
            ),
          // Paste image
          _ToolButton(
            icon: Icons.image_outlined,
            active: false,
            tooltip: 'Paste image URL',
            onTap: onPasteImage,
          ),
          const SizedBox(width: 4),
          // Clear
          _ToolButton(
            icon: Icons.delete_sweep_outlined,
            active: false,
            tooltip: 'Clear drawing',
            onTap: onClear,
          ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  const _ToolButton({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: active
                ? EchoTheme.accent.withValues(alpha: 0.2)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 20,
            color: active ? EchoTheme.accent : context.textSecondary,
          ),
        ),
      ),
    );
  }
}
