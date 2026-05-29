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

/// Interactive voice-lounge canvas.
///
/// Features:
///   • Draggable circular avatars with speaking ring
///   • Paste/drop images pinned to the canvas
///   • All state synced in real-time via WebSocket
///   • Persistent board state loaded from the server on join
///
/// Stroke rendering lives in `LoungeCanvasStrokes` (see canvas-rewrite
/// PR-B chunk 2). The lounge screen mounts the two as siblings under a
/// single `Stack`; this widget no longer paints strokes.
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

  /// Fixed canvas size shared by every participant. The InteractiveViewer in
  /// the parent screen scales + pans this surface; downstream painters and
  /// positioned widgets work in absolute canvas-space pixels.
  static const Size _canvasSize = Size(kCanvasWidth, kCanvasHeight);

  /// Convert a pointer event whose `localPosition` is already in the
  /// child-of-InteractiveViewer coordinate space (= canvas space) into a
  /// [CanvasPoint]. Clamping prevents strokes from being persisted with
  /// negative or out-of-canvas coordinates if a quick gesture overshoots.
  CanvasPoint _toCanvasPoint(Offset canvasSpace) {
    return CanvasPoint(
      x: canvasSpace.dx.clamp(0.0, kCanvasWidth),
      y: canvasSpace.dy.clamp(0.0, kCanvasHeight),
    );
  }

  Offset _toLocal(CanvasPoint pt) => Offset(pt.x, pt.y);

  /// Opens a small text-entry dialog and commits the result as a text label
  /// at [anchor]. Returns immediately when the canvas isn't usable (no
  /// channel id yet) so the user doesn't see a no-op dialog.
  Future<void> _promptTextLabel(CanvasPoint anchor) async {
    final controller = TextEditingController();
    final canvas = ref.read(canvasProvider);
    // Cache the values so the closure doesn't re-read provider mid-dialog.
    final fontSize = canvas.strokeWidth.clamp(10.0, 64.0);
    final color = canvas.currentColor;
    final committed = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add text'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 200,
          decoration: const InputDecoration(hintText: 'Type a label…'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (committed == null || committed.trim().isEmpty) return;
    ref
        .read(canvasProvider.notifier)
        .addTextLabel(
          anchor: anchor,
          text: committed,
          fontSize: fontSize,
          color: color,
        );
  }

  @override
  Widget build(BuildContext context) {
    final canvas = ref.watch(canvasProvider);
    final authState = ref.watch(authProvider);
    final myUserId = authState.userId ?? '';

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) => _handleKeyEvent(event),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        child: RepaintBoundary(
          key: voiceCanvasRepaintKey,
          // The Stack is sized to the fixed canvas dimensions so the parent
          // InteractiveViewer scales the whole 4096×4096 surface uniformly.
          // Every Positioned child below works in absolute canvas-space
          // pixels — circles drawn on a phone read as circles on desktop.
          child: SizedBox(
            width: kCanvasWidth,
            height: kCanvasHeight,
            child: Stack(
              key: _canvasKey,
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: _DrawingLayer(
                    canvas: canvas,
                    // Drawing-tool pointer input is owned by
                    // LoungeDrawingCanvas (an opaque overlay placed by
                    // voice_lounge_screen.dart). That widget uses a
                    // PanGestureRecognizer so a second pointer cancels and
                    // InteractiveViewer can pinch — semantics that a bare
                    // Listener can't replicate. _DrawingLayer keeps the
                    // text-tool tap-to-place because the prompt closure
                    // lives in this widget's State (audit Finding 1,
                    // 2026-05-28).
                    onTextTap: (offset) =>
                        _promptTextLabel(_toCanvasPoint(offset)),
                  ),
                ),
                ..._buildImages(canvas, authState),
                ..._buildAvatars(canvas, myUserId, authState),
              ],
            ),
          ),
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
    const size = _canvasSize;
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
    final scale = normalized.scale;
    final offset = _toLocal(CanvasPoint(x: normalized.x, y: normalized.y));

    final effectiveSize = _kAvatarSize * scale;
    final effectiveHalf = effectiveSize / 2;
    final left = (offset.dx - effectiveHalf).clamp(
      0.0,
      canvasSize.width > effectiveSize ? canvasSize.width - effectiveSize : 0.0,
    );
    final top = (offset.dy - effectiveHalf).clamp(
      0.0,
      canvasSize.height > effectiveSize
          ? canvasSize.height - effectiveSize
          : 0.0,
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
        scale: scale,
        attention: attention,
        httpHeaders: authState.token != null
            ? {'Authorization': 'Bearer ${authState.token}'}
            : null,
        onDrag: (norm) {
          ref
              .read(canvasProvider.notifier)
              .moveAvatar(participant.userId, norm);
        },
        onDragEnd: (norm) {
          ref
              .read(canvasProvider.notifier)
              .commitAvatarMove(participant.userId, norm);
        },
        onResize: (dx, dy) {
          // Diagonal grip — use the larger of dx + dy so the user feels
          // a uniform resize regardless of which axis they pull. Pixel
          // delta over the base 48 px tile sets the per-frame scale step.
          final delta = (dx + dy) / 2.0;
          final current = normalized.scale;
          final next = current + delta / _kAvatarSize;
          ref
              .read(canvasProvider.notifier)
              .resizeAvatar(participant.userId, next);
        },
        onResizeEnd: () => ref
            .read(canvasProvider.notifier)
            .commitAvatarResize(participant.userId),
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
    const cx = kCanvasWidth / 2;
    const cy = kCanvasHeight / 2;
    if (total <= 1) return AvatarPosition(userId: userId, x: cx, y: cy);
    final angle = (2 * math.pi * index) / total;
    // Radius = 30% of the shorter canvas axis so all defaults land well
    // inside the visible region at minScale.
    const r = 0.3 * kCanvasWidth;
    return AvatarPosition(
      userId: userId,
      x: cx + r * math.cos(angle),
      y: cy + r * math.sin(angle),
    );
  }

  List<Widget> _buildImages(CanvasState canvas, AuthState authState) {
    final token = authState.token;
    final httpHeaders = token != null
        ? <String, String>{'Authorization': 'Bearer $token'}
        : null;
    return canvas.images.map((img) {
      return Positioned(
        left: img.x,
        top: img.y,
        width: img.width,
        height: img.height,
        child: _CanvasImageWidget(
          image: img,
          httpHeaders: httpHeaders,
          onMove: (dx, dy) {
            final current = ref
                .read(canvasProvider)
                .images
                .where((i) => i.id == img.id)
                .firstOrNull;
            final curX = current?.x ?? img.x;
            final curY = current?.y ?? img.y;
            final w = current?.width ?? img.width;
            final h = current?.height ?? img.height;
            // Clamp the LEFT edge to (0, canvas - width) so the whole
            // image stays inside the canvas. Previously clamped to
            // (0, canvas) which let the right edge drift off-screen by
            // the image's full width (audit Finding 7, 2026-05-28).
            // Guard against an oversized image (w > canvas) by allowing
            // x = 0 in that case rather than producing a negative clamp.
            final maxX = (kCanvasWidth - w).clamp(0.0, kCanvasWidth);
            final maxY = (kCanvasHeight - h).clamp(0.0, kCanvasHeight);
            final newX = (curX + dx).clamp(0.0, maxX);
            final newY = (curY + dy).clamp(0.0, maxY);
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
            final curW = current?.width ?? img.width;
            final curH = current?.height ?? img.height;
            final newW = (curW + dx).clamp(32.0, kCanvasWidth);
            final newH = (curH + dy).clamp(32.0, kCanvasHeight);
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
    // Spawn dead-centre. The drag-and-drop or paste action that lands here
    // already represents intent — the user shouldn't have to chase a
    // random off-centre placement to start working with the image.
    const w = kCanvasWidth * 0.25;
    const h = kCanvasHeight * 0.25;
    final img = CanvasImage(
      id: newCanvasId(),
      url: url,
      x: kCanvasWidth / 2 - w / 2,
      y: kCanvasHeight / 2 - h / 2,
      width: w,
      height: h,
    );
    ref.read(canvasProvider.notifier).addImage(img);
  }
}

/// Text-tool tap target only.
///
/// Originally also handled drawing-tool pointer input + stroke painting,
/// but those responsibilities were peeled out:
///   * drawing-tool pointer input moved to [LoungeDrawingCanvas] in
///     2026-05-28 (audit Finding 1) because a bare [Listener] can't
///     cancel mid-gesture when a second pointer arrives.
///   * stroke painting moved to `LoungeCanvasStrokes` in canvas-rewrite
///     PR-B chunk 2 — that widget owns the three-layer RepaintBoundary
///     split and pipes points through perfect_freehand. See
///     docs/voice-lounge/05-canvas-rewrite-spec.md §B.2.
///
/// What's left here: a single-tap pointer hook that opens the text-entry
/// dialog when the text tool is selected. The text-tool flow is anchored
/// to this widget's parent State (it owns the prompt closure), which is
/// why it stays in `voice_canvas.dart` rather than moving to the strokes
/// widget.
class _DrawingLayer extends StatelessWidget {
  final CanvasState canvas;
  final void Function(Offset) onTextTap;

  const _DrawingLayer({required this.canvas, required this.onTextTap});

  @override
  Widget build(BuildContext context) {
    final isText = canvas.selectedTool == CanvasTool.text;
    return Listener(
      // `deferToChild` so avatars and images stay draggable underneath
      // when no drawing/text tool is active and so the
      // LoungeDrawingCanvas overlay (above this in the parent Stack)
      // remains the sole owner of drag pointer events.
      behavior: isText ? HitTestBehavior.opaque : HitTestBehavior.deferToChild,
      onPointerDown: isText
          ? (e) {
              if (e.buttons != kPrimaryButton) return;
              onTextTap(e.localPosition);
            }
          : null,
      child: const SizedBox.expand(),
    );
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

  /// User-controlled size multiplier on top of [_kAvatarSize]. 1.0 = the
  /// historical default 48 px puck.
  final double scale;

  final void Function(CanvasPoint norm) onDrag;
  final void Function(CanvasPoint norm) onDragEnd;

  /// Called while the user drags the bottom-right resize handle. [dx], [dy]
  /// are pixel deltas; the parent translates them to a new scale factor.
  final void Function(double dx, double dy)? onResize;
  final VoidCallback? onResizeEnd;

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
    this.scale = 1.0,
    this.onResize,
    this.onResizeEnd,
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
  bool _hovered = false;

  /// Distance from the ring centre at the start of a resize pan, in local
  /// (ring-relative) pixels. Used to translate radial pointer motion into
  /// per-frame scale deltas, so the gesture feels uniform regardless of
  /// which side of the ring the user grabbed.
  double? _resizeStartRadius;

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

  double get _effectiveAvatarSize => _kAvatarSize * widget.scale;

  Widget _buildAvatarTile(
    _ParticipantInfo info,
    Widget innerContent,
    bool hasVideo,
  ) {
    final hue = (info.userId.hashCode % 360).abs().toDouble();
    final avatarColor = HSLColor.fromAHSL(1.0, hue, 0.5, 0.35).toColor();

    return Container(
      width: _effectiveAvatarSize,
      height: _effectiveAvatarSize,
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
            width: _effectiveAvatarSize,
            height: _effectiveAvatarSize,
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
    final withRing = _wrapInResizeRing(avatar);
    if (_reduceMotion) return withRing;

    // Keep trail layer mounted (idle painter returns early) to avoid CustomPaint remount when buffer flips empty/non-empty.
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size(_effectiveAvatarSize, _effectiveAvatarSize),
              painter: _TrailPainter(
                trail: _trail,
                currentPos: _localPos ?? widget.currentPos,
                // Trail deltas are now in absolute canvas-space pixels —
                // PuckTrail.render multiplies by canvasSize.width/height, so
                // pass unit Size to keep deltas at their natural pixel scale.
                canvasSize: const Size(1, 1),
                color: EchoTheme.online,
                radius: _effectiveAvatarSize * 0.225,
                tick: _trailTick,
              ),
            ),
          ),
        ),
        withRing,
      ],
    );
  }

  /// Wraps the avatar tile in a circular click-and-drag resize ring.
  /// When [onResize] is null (callers that don't want resize, e.g. tests)
  /// this is a no-op so the avatar renders unwrapped. On hover the ring
  /// becomes visible. The gesture is radial: pulling the cursor away from
  /// the avatar centre grows it, pushing toward the centre shrinks it —
  /// regardless of which side of the ring the user grabbed. Previously
  /// the code averaged `(dx + dy) / 2` of the per-frame delta, which felt
  /// inverted on the left and top quadrants of the ring (dragging
  /// outward in those directions returned negative deltas and shrank
  /// the avatar).
  Widget _wrapInResizeRing(Widget avatar) {
    if (widget.onResize == null) return avatar;
    const ringThickness = 6.0;
    final ringSize = _effectiveAvatarSize + ringThickness * 2;
    final ringCenter = Offset(ringSize / 2, ringSize / 2);
    return SizedBox(
      width: ringSize,
      height: ringSize,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // Bottom layer: perimeter gesture catcher + visible ring on
          // hover. HitTestBehavior.opaque on the full square, but a
          // smaller centered IgnorePointer hole lets the inner move
          // drag through (next layer).
          MouseRegion(
            cursor: SystemMouseCursors.resizeUpRightDownLeft,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onPanStart: (d) {
                _resizeStartRadius = (d.localPosition - ringCenter).distance;
              },
              onPanUpdate: (d) {
                final start = _resizeStartRadius;
                if (start == null || start <= 0) return;
                final currentRadius = (d.localPosition - ringCenter).distance;
                // Per-frame radial delta. Positive when the pointer moved
                // away from centre, negative when toward — true to user
                // intuition regardless of which quadrant the gesture
                // started in.
                final delta = currentRadius - start;
                _resizeStartRadius = currentRadius;
                widget.onResize!(delta, delta);
              },
              onPanEnd: (_) {
                _resizeStartRadius = null;
                widget.onResizeEnd?.call();
              },
              onPanCancel: () => _resizeStartRadius = null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: ringSize,
                height: ringSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _hovered
                        ? context.accent.withValues(alpha: 0.6)
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
          // Top layer: actual avatar tile. Sized to the original
          // _effectiveAvatarSize so the surrounding ring stays clickable
          // for resize.
          avatar,
        ],
      ),
    );
  }

  Widget _buildContent(_ParticipantInfo info, Widget avatarWithTrail) {
    // Username label appears only on hover — keeps the canvas clean when
    // there are many participants. The label sits beneath the puck and
    // is reserved as a 16 px slot at all times so neighbour avatars
    // don't jump on hover.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        avatarWithTrail,
        const SizedBox(height: 4),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: _hovered ? 1.0 : 0.0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: context.surface.withValues(alpha: 0.7),
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
        ),
      ],
    );
  }

  Widget _buildDraggableWrapper(Widget content) {
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            // Win the gesture arena on pointer-down (see _CanvasImageWidget
            // for full rationale). Avatars are smaller targets and a brief
            // moment of arena-fight with InteractiveViewer can detach them
            // mid-drag.
            dragStartBehavior: DragStartBehavior.down,
            onDoubleTap: widget.onDoubleTap,
            onPanUpdate: (details) {
              // Pointer delta is in canvas-space pixels because the
              // GestureDetector lives inside the InteractiveViewer-scaled
              // surface, so we can apply it 1:1 against current canvas
              // coords. Clamp to the fixed canvas extent.
              final base = _localPos ?? widget.currentPos;
              final newPos = CanvasPoint(
                x: (base.x + details.delta.dx).clamp(0.0, kCanvasWidth),
                y: (base.y + details.delta.dy).clamp(0.0, kCanvasHeight),
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
          // Resize ring lives inside _wrapInResizeRing (avatar-tile
          // sibling), so no corner button is needed here.
        ],
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
        // DragStartBehavior.down: the inner image's pan recognizer wins
        // the gesture arena on pointer-down instead of waiting for
        // kPanSlop. Without this, a fast drag occasionally lost
        // arbitration to the parent InteractiveViewer's PanGestureRecognizer
        // mid-gesture and detached, forcing the user to click and start
        // the drag over (user-reported 2026-05-27).
        dragStartBehavior: DragStartBehavior.down,
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
                    dragStartBehavior: DragStartBehavior.down,
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
