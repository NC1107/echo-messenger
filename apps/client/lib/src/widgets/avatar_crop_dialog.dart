import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../theme/echo_theme.dart';

/// Decodes [bytes] into an [img.Image] suitable for cropping.
///
/// The `image` package handles JPEG, PNG, GIF, WebP, BMP and TIFF directly.
/// On iOS the gallery often hands back HEIC, which `image` does not support
/// — that produced the "could not decode image" failure in #796. When the
/// fast path fails we sniff for HEIC / HEIF / AVIF magic bytes and fall
/// back to Flutter's platform decoder via [ui.instantiateImageCodec], which
/// uses the iOS native HEIC decoder. The first frame is re-encoded as PNG
/// and fed back through the `image` package so cropping can proceed.
///
/// Returns null when both decoders fail.
Future<img.Image?> decodeAvatarImage(Uint8List bytes) {
  if (bytes.isEmpty) return Future.value(null);

  // image's decodeImage can throw on truncated/garbage input rather than
  // returning null, so wrap the fast path defensively.
  img.Image? direct;
  try {
    direct = img.decodeImage(bytes);
  } catch (_) {
    direct = null;
  }
  if (direct != null) return Future.value(direct);

  // Platform codec only for HEIF family — unconditional fallback would hide malformed input and stall widget tests.
  if (_looksLikeHeifFamily(bytes)) {
    return _decodeViaPlatformCodec(bytes);
  }
  return Future.value(null);
}

// Detect HEIC / HEIF / AVIF by looking at the ISOBMFF `ftyp` box brand at
// offset 8-11. Returns false on anything that isn't an ISOBMFF container.
bool _looksLikeHeifFamily(Uint8List bytes) {
  if (bytes.length < 12) return false;
  if (bytes[4] != 0x66 ||
      bytes[5] != 0x74 ||
      bytes[6] != 0x79 ||
      bytes[7] != 0x70) {
    return false; // bytes 4-7 != "ftyp"
  }
  const heifBrands = {
    'heic',
    'heix',
    'heim',
    'heis',
    'mif1',
    'msf1',
    'avif',
    'avis',
    'avi1',
  };
  final brand = String.fromCharCodes(bytes.sublist(8, 12));
  return heifBrands.contains(brand);
}

Future<img.Image?> _decodeViaPlatformCodec(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final pngData = await frame.image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    frame.image.dispose();
    codec.dispose();
    if (pngData == null) return null;
    return img.decodePng(pngData.buffer.asUint8List());
  } catch (_) {
    return null;
  }
}

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

  // Desktop gets a roomier preview because mouse users can't pinch-zoom.
  static const _previewSizeMobile = 280.0;
  static const _previewSizeDesktop = 460.0;
  double _previewSize = _previewSizeMobile;

  /// Cached minimum scale at which the image still covers the preview
  /// square. Recomputed only when the image decodes or the preview
  /// viewport flips between mobile/desktop. Avoids the per-frame
  /// `_previewSize / min(imgW, imgH)` arithmetic in build() that the
  /// performance reviewer flagged in TD-13.
  double _minScale = 1.0;

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Pick a roomier viewport on desktop where pinch isn't available.
    // The phone-friendly default stays for narrow viewports.
    final w = MediaQuery.sizeOf(context).width;
    final isDesktop = w >= 800;
    final desired = isDesktop ? _previewSizeDesktop : _previewSizeMobile;
    if (_previewSize == desired) return;
    // TD-12: setState so mask/slider-min/preview all see the new _previewSize.
    setState(() {
      _previewSize = desired;
      if (_decoded != null) {
        _refitToViewport();
      }
    });
  }

  /// Recompute scale + offset to center the decoded image inside the
  /// current `_previewSize`. Also refreshes `_minScale` so the zoom
  /// slider doesn't have to derive it per build (TD-13).
  void _refitToViewport() {
    if (_decoded == null) return;
    final imgW = _decoded!.width.toDouble();
    final imgH = _decoded!.height.toDouble();
    _minScale = _previewSize / (imgW < imgH ? imgW : imgH);
    _scale = _minScale;
    final scaledW = imgW * _scale;
    final scaledH = imgH * _scale;
    _offset = Offset(
      (_previewSize - scaledW) / 2,
      (_previewSize - scaledH) / 2,
    );
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
      // Cache minScale so the Slider doesn't recompute per frame (TD-13).
      final minScale = _previewSize / (imgW < imgH ? imgW : imgH);
      final scaledW = imgW * minScale;
      final scaledH = imgH * minScale;
      final initOffset = Offset(
        (_previewSize - scaledW) / 2,
        (_previewSize - scaledH) / 2,
      );
      setState(() {
        _decoded = decoded;
        _minScale = minScale;
        _scale = minScale;
        _offset = initOffset;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to decode image: $e');
    }
  }

  static Future<img.Image?> _decodeAsync(Uint8List bytes) =>
      decodeAvatarImage(bytes);

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

  /// Mouse / accessibility slider — bumps [_scale] without pinch.
  /// Keeps the image centred on the new scale so the crop frame stays
  /// sensible across the full range.
  void _onZoomSliderChanged(double newScale) {
    if (_decoded == null) return;
    final imgW = _decoded!.width.toDouble();
    final imgH = _decoded!.height.toDouble();
    final minScale = _previewSize / (imgW < imgH ? imgW : imgH);
    final clamped = newScale.clamp(minScale, 6.0);
    // Anchor the zoom on the centre of the preview so the user's frame
    // doesn't drift off-axis.
    final centre = Offset(_previewSize / 2, _previewSize / 2);
    final ratio = clamped / _scale;
    final newOffset = Offset(
      centre.dx - (centre.dx - _offset.dx) * ratio,
      centre.dy - (centre.dy - _offset.dy) * ratio,
    );
    // Inline clamp using the new scale; _clampOffset reads _scale via
    // closure, so apply the update first then clamp.
    final scaledW = imgW * clamped;
    final scaledH = imgH * clamped;
    final minX = _previewSize - scaledW;
    final minY = _previewSize - scaledH;
    setState(() {
      _scale = clamped;
      _offset = Offset(
        newOffset.dx.clamp(minX, 0.0),
        newOffset.dy.clamp(minY, 0.0),
      );
    });
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
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('Crop Avatar'),
          SizedBox(
            width: 44,
            height: 44,
            child: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: Icon(
                Icons.close,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
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
                  style: const TextStyle(color: EchoTheme.danger, fontSize: 12),
                ),
              ),
            Text(
              'Drag to frame · use the slider to zoom',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            _buildCropPreview(),
            if (_decoded != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.zoom_out,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  Expanded(
                    child: Slider(
                      min: _minScale,
                      max: 6.0,
                      value: _scale.clamp(_minScale, 6.0),
                      onChanged: _onZoomSliderChanged,
                    ),
                  ),
                  Icon(
                    Icons.zoom_in,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ],
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
              Container(color: context.surfaceHover),

              if (_decoded != null)
                Positioned(
                  left: _offset.dx,
                  top: _offset.dy,
                  child: Image.memory(
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
                size: Size(_previewSize, _previewSize),
                painter: _CircleMaskPainter(scrim: context.overlayScrim),
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
  final Color scrim;

  _CircleMaskPainter({required this.scrim});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;

    // Dark overlay excluding the circle (Slice 8: themed scrim).
    final path = Path()
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: center, radius: radius))
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, Paint()..color = scrim);

    // Circle border — stays white so the guide remains visible on any scrim.
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
  bool shouldRepaint(_CircleMaskPainter oldDelegate) =>
      oldDelegate.scrim != scrim;
}
