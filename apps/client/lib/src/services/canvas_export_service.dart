import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../models/canvas_models.dart';

/// Helpers for importing / exporting the shared voice-lounge canvas.
///
/// The canvas is rendered inside a [RepaintBoundary] keyed by
/// `voiceCanvasRepaintKey` (see `widgets/voice_canvas.dart`). PNG capture
/// walks that boundary's render tree; JSON capture round-trips through the
/// existing `CanvasStroke.toJson` / `CanvasImage.toJson` model helpers.
class CanvasExportService {
  CanvasExportService._();

  /// Snapshot version surfaced on disk so a future import can tell when
  /// it's reading an incompatible payload.
  static const int snapshotFormatVersion = 1;

  /// Maximum pixel dimension safe on mobile GPUs (most cap at 4096–8192).
  /// Using 4096 keeps us inside even the most conservative Android devices.
  static const double _kMaxTextureDim = 4096;

  /// Minimum pixel ratio to keep the output legible even on tiny boundaries.
  static const double _kMinPixelRatio = 0.5;

  /// Clamp [pixelRatio] so that neither dimension of the rendered image
  /// exceeds [maxDim] pixels. Protects against "invalid arguments" on Android
  /// when the boundary size × ratio overflows the GPU texture limit.
  ///
  /// This is a pure helper exposed for testing.
  static double clampPixelRatio(
    Size boundarySize, {
    double pixelRatio = 2.0,
    double maxDim = _kMaxTextureDim,
    double minRatio = _kMinPixelRatio,
  }) {
    final longest = math.max(boundarySize.width, boundarySize.height);
    if (longest <= 0) return minRatio;
    final clamped = math.min(pixelRatio, maxDim / longest);
    return math.max(clamped, minRatio);
  }

  /// Capture the active canvas as a PNG. Returns the PNG bytes ready to be
  /// written to disk. Caller is responsible for picking a destination path
  /// — most surfaces will use `file_picker.saveFile`.
  static Future<Uint8List> capturePng(
    GlobalKey repaintKey, {
    double pixelRatio = 2.0,
  }) async {
    final object = repaintKey.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary) {
      throw StateError('Voice canvas repaint boundary is not mounted yet.');
    }
    final effectiveRatio = clampPixelRatio(object.size, pixelRatio: pixelRatio);
    final image = await object.toImage(pixelRatio: effectiveRatio);
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw StateError('Failed to encode canvas image to PNG.');
      }
      return byteData.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// Serialize the persistent parts of [state] (strokes + images) to a
  /// JSON string. Avatar positions and in-progress drawing state are
  /// excluded — they're ephemeral and would clash with the live
  /// participants on import.
  static String encodeJson(CanvasState state) {
    final payload = {
      'format_version': snapshotFormatVersion,
      'strokes': state.strokes.map((s) => s.toJson()).toList(),
      'images': state.images.map((i) => i.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Parse a JSON snapshot previously produced by [encodeJson]. Throws
  /// [FormatException] on a malformed payload so callers can surface an
  /// error toast without leaving the canvas in a partial state.
  static ({List<CanvasStroke> strokes, List<CanvasImage> images}) decodeJson(
    String json,
  ) {
    final dynamic root = jsonDecode(json);
    if (root is! Map<String, dynamic>) {
      throw const FormatException(
        'Canvas snapshot root must be a JSON object.',
      );
    }
    final version = root['format_version'];
    if (version is! int || version != snapshotFormatVersion) {
      throw FormatException(
        'Unsupported canvas snapshot format_version: $version. '
        'Expected $snapshotFormatVersion.',
      );
    }
    final strokesRaw = root['strokes'];
    final imagesRaw = root['images'];
    if (strokesRaw is! List || imagesRaw is! List) {
      throw const FormatException(
        'Canvas snapshot is missing strokes / images arrays.',
      );
    }
    final strokes = <CanvasStroke>[];
    for (final raw in strokesRaw) {
      if (raw is Map<String, dynamic>) {
        strokes.add(CanvasStroke.fromJson(raw));
      }
    }
    final images = <CanvasImage>[];
    for (final raw in imagesRaw) {
      if (raw is Map<String, dynamic>) {
        images.add(CanvasImage.fromJson(raw));
      }
    }
    return (strokes: strokes, images: images);
  }
}
