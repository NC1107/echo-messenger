import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Shows a modal crop dialog for an avatar image.
///
/// [rawBytes] is the full image data from the file picker.
/// Returns a [Uint8List] with the cropped, square JPEG (max 1024×1024, ≤500 KB)
/// on confirm, or `null` if the user cancels.
///
/// The crop UI works on every platform (Linux, web, mobile, desktop).
/// A circular overlay is shown as a visual guide — the actual saved file is
/// square (CircleAvatar clips it visually on display).
Future<Uint8List?> showAvatarCropDialog(
  BuildContext context,
  Uint8List rawBytes,
) {
  return showDialog<Uint8List>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AvatarCropDialog(rawBytes: rawBytes),
  );
}

class _AvatarCropDialog extends StatefulWidget {
  final Uint8List rawBytes;

  const _AvatarCropDialog({required this.rawBytes});

  @override
  State<_AvatarCropDialog> createState() => _AvatarCropDialogState();
}

class _AvatarCropDialogState extends State<_AvatarCropDialog> {
  // The decoded image (nullable until async decode completes).
  img.Image? _decoded;

  // Viewport dimensions for the preview area.
  static const _previewSize = 280.0;

  // Scale and offset of the image inside the preview square.
  // The image is scaled so its shorter side fills the preview initially.
  double _scale = 1.0;
  Offset _offset = Offset.zero;

  // Pinch tracking
  double? _baseScale;
  Offset? _baseFocalPoint;
  Offset? _baseOffset;

  bool _processing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    try {
      final decoded = await _decodeAsync(widget.rawBytes);
      if (!mounted) return;
      if (decoded == null) {
        setState(() => _error = 'Could not decode image');
        return;
      }
      final imgW = decoded.width.toDouble();
      final imgH = decoded.height.toDouble();
      // Scale so the shorter side covers the preview square.
      final initScale = _previewSize / (imgW < imgH ? imgW : imgH);
      // Centre the image.
      final scaledW = imgW * initScale;
      final scaledH = imgH * initScale;
      final initOffset = Offset(
        (_previewSize - scaledW) / 2,
        (_previewSize - scaledH) / 2,
      );
      setState(() {
        _decoded = decoded;
        _scale = initScale;
        _offset = initOffset;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to decode image: $e');
    }
  }

  static Future<img.Image?> _decodeAsync(Uint8List bytes) async {
    return img.decodeImage(bytes);
  }

  // Clamp offset so the crop square (previewSize×previewSize) is always
  // fully covered by the image — no empty space inside the circle.
  Offset _clampOffset(Offset raw) {
    if (_decoded == null) return raw;
    final scaledW = _decoded!.width * _scale;
    final scaledH = _decoded!.height * _scale;
    final minX = _previewSize - scaledW;
    final minY = _previewSize - scaledH;
    return Offset(raw.dx.clamp(minX, 0.0), raw.dy.clamp(minY, 0.0));
  }

  void _onScaleStart(ScaleStartDetails details) {
    _baseScale = _scale;
    _baseFocalPoint = details.focalPoint;
    _baseOffset = _offset;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_decoded == null) return;
    final imgW = _decoded!.width.toDouble();
    final imgH = _decoded!.height.toDouble();
    final minScale = _previewSize / (imgW < imgH ? imgW : imgH);

    final newScale = (_baseScale! * details.scale).clamp(minScale, 6.0);
    // Adjust offset so the focal point stays fixed during pinch.
    final scaleRatio = newScale / _baseScale!;
    final focalDelta = details.focalPoint - _baseFocalPoint!;
    final newOffset = Offset(
      _baseOffset!.dx * scaleRatio +
          focalDelta.dx -
          (_baseFocalPoint!.dx - _offset.dx) * (scaleRatio - 1),
      _baseOffset!.dy * scaleRatio +
          focalDelta.dy -
          (_baseFocalPoint!.dy - _offset.dy) * (scaleRatio - 1),
    );

    setState(() {
      _scale = newScale;
      _offset = _clampOffset(newOffset);
    });
  }

  Future<void> _confirm() async {
    if (_decoded == null) return;
    setState(() => _processing = true);

    try {
      final result = await _cropAsync(_decoded!, _scale, _offset, _previewSize);
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) {
        setState(() {
          _processing = false;
          _error = 'Crop failed: $e';
        });
      }
    }
  }

  static Future<Uint8List> _cropAsync(
    img.Image source,
    double scale,
    Offset offset,
    double previewSize,
  ) async {
    // Map the previewSize square back into source-image coordinates.
    final srcX = (-offset.dx / scale).round().clamp(0, source.width - 1);
    final srcY = (-offset.dy / scale).round().clamp(0, source.height - 1);
    final srcSize = (previewSize / scale).round();
    final clampedW = srcSize.clamp(1, source.width - srcX);
    final clampedH = srcSize.clamp(1, source.height - srcY);

    var cropped = img.copyCrop(
      source,
      x: srcX,
      y: srcY,
      width: clampedW,
      height: clampedH,
    );

    // Resize to max 1024×1024.
    if (cropped.width > 1024 || cropped.height > 1024) {
      cropped = img.copyResize(cropped, width: 1024, height: 1024);
    }

    // Encode as JPEG at quality 85 (typically well under 500 KB for 1024²).
    final jpeg = img.encodeJpg(cropped, quality: 85);

    // If still over 500 KB, re-encode at lower quality.
    if (jpeg.length > 500 * 1024) {
      final q = ((85 * 500 * 1024) / jpeg.length).clamp(40, 85).toInt();
      return Uint8List.fromList(img.encodeJpg(cropped, quality: q));
    }

    return Uint8List.fromList(jpeg);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Crop Avatar'),
      content: SizedBox(
        width: _previewSize,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
            Text(
              'Pan and pinch to frame your avatar',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            _buildCropPreview(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _processing ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: (_decoded == null || _processing || _error != null)
              ? null
              : _confirm,
          child: _processing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Use Photo'),
        ),
      ],
    );
  }

  Widget _buildCropPreview() {
    return SizedBox(
      width: _previewSize,
      height: _previewSize,
      child: ClipRect(
        child: GestureDetector(
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          child: Stack(
            children: [
              // Checkerboard background (shows when no image yet).
              Container(color: Colors.grey.shade800),

              if (_decoded != null)
                Positioned(
                  left: _offset.dx,
                  top: _offset.dy,
                  child: Image.memory(
                    // Re-encode a thumbnail for display to avoid re-decoding
                    // the full bitmap every frame. We cache the memory image
                    // from rawBytes directly.
                    widget.rawBytes,
                    width: _decoded!.width * _scale,
                    height: _decoded!.height * _scale,
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                  ),
                )
              else if (_error == null)
                const Center(child: CircularProgressIndicator()),

              // Circular mask overlay — darkened corners, bright circle border.
              CustomPaint(
                size: const Size(_previewSize, _previewSize),
                painter: _CircleMaskPainter(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paints a semi-transparent dark overlay with a circular cut-out and a
/// light ring border to guide the user's framing.
class _CircleMaskPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;

    // Dark overlay excluding the circle.
    final path = Path()
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: center, radius: radius))
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(
      path,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    // Circle border.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white.withValues(alpha: 0.8)
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_CircleMaskPainter oldDelegate) => false;
}
