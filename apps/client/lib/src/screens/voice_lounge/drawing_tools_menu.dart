/// Drawing tools popup menu used by the floating dock's draw submenu.
library;

import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/canvas_models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/canvas_provider.dart';
import '../../providers/server_url_provider.dart';
import '../../services/canvas_export_service.dart';
import '../../services/chunked_upload_client.dart';
import '../../services/toast_service.dart';
import '../../services/upload_client.dart';
import '../../theme/echo_theme.dart';
import '../../theme/motion_tokens.dart';
import '../../utils/canvas_utils.dart';
import '../../widgets/voice_canvas.dart' show voiceCanvasRepaintKey;

/// Popup content for the drawing tools menu.
class DrawingToolsMenu extends ConsumerStatefulWidget {
  final VoidCallback onToggleDrawing;
  final bool isDrawing;
  final String conversationId;
  final VoidCallback? onRequestClose;

  const DrawingToolsMenu({
    super.key,
    required this.onToggleDrawing,
    required this.isDrawing,
    required this.conversationId,
    this.onRequestClose,
  });

  @override
  ConsumerState<DrawingToolsMenu> createState() => _DrawingToolsMenuState();
}

class _DrawingToolsMenuState extends ConsumerState<DrawingToolsMenu> {
  // The menu mirrors a slice of `canvasProvider` state for its own
  // selected-chip highlighting.  The provider is the source of truth for
  // actual drawing values; these locals just cache the latest selection
  // so the chips render synchronously without an extra ref.watch.
  CanvasTool _selectedTool = CanvasTool.pen;
  Color _selectedColor = Colors.white;
  double _selectedSize = 4.0;

  static const _penColors = [
    Colors.white,
    Colors.red,
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.cyan,
    Colors.blue,
    Colors.purple,
    Colors.pink,
  ];

  @override
  void initState() {
    super.initState();
    // Hydrate from the provider so the menu opens with the current selection.
    // `none` means the drawing layer is off; show "pen" as the default
    // selected tool, but don't push it back into the provider — that would
    // arm the drawing layer just by opening the menu.
    final canvas = ref.read(canvasProvider);
    _selectedTool = canvas.selectedTool == CanvasTool.none
        ? CanvasTool.pen
        : canvas.selectedTool;
    _selectedColor = canvas.currentColor;
    _selectedSize = canvas.strokeWidth;
  }

  @override
  Widget build(BuildContext context) {
    // 280 px target, clamped down to the device's safe width minus a
    // 16 px margin per side so the popup never overflows on narrow
    // phones (iPhone SE at 320 logical width has exactly 288 usable
    // and the old fixed 280 risked off-screen popup chrome).
    final maxAllowed = (MediaQuery.sizeOf(context).width - 32).clamp(
      220.0,
      320.0,
    );
    final menuWidth = math.min(280.0, maxAllowed);
    return SizedBox(
      width: menuWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildToolSelector(context),
          // Eraser strips colour + ignores the colour picker, but every
          // other tool (pen, highlighter, shapes) is colour + size aware.
          if (_selectedTool != CanvasTool.eraser) ...[
            const Divider(height: 1),
            _buildColorPicker(context),
            const SizedBox(height: 4),
            const Divider(height: 1),
            _buildSizePicker(context),
          ] else ...[
            const Divider(height: 1),
            _buildSizePicker(context),
          ],
          const Divider(height: 12),
          _buildActionButtons(context),
        ],
      ),
    );
  }

  Widget _buildToolSelector(BuildContext context) {
    // Single tight row of icon-only buttons. Tooltips carry the label so
    // the menu stays compact (the previous wrapping labelled chips made
    // the popup nearly twice as tall — user feedback 2026-05-27).
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _toolIcon(context, Icons.edit, 'Pen tool', CanvasTool.pen),
          _toolIcon(
            context,
            Icons.brush,
            'Highlighter tool',
            CanvasTool.highlighter,
          ),
          _toolIcon(context, Icons.show_chart, 'Line tool', CanvasTool.line),
          _toolIcon(
            context,
            Icons.crop_square,
            'Rectangle tool',
            CanvasTool.rect,
          ),
          _toolIcon(
            context,
            Icons.circle_outlined,
            'Ellipse tool',
            CanvasTool.ellipse,
          ),
          _toolIcon(context, Icons.text_fields, 'Text tool', CanvasTool.text),
          _toolIcon(
            context,
            Icons.auto_fix_high,
            'Eraser tool',
            CanvasTool.eraser,
          ),
        ],
      ),
    );
  }

  Widget _toolIcon(
    BuildContext context,
    IconData icon,
    String label,
    CanvasTool tool,
  ) {
    final isSelected = _selectedTool == tool;
    return Semantics(
      label: label,
      button: true,
      selected: isSelected,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() => _selectedTool = tool);
            ref.read(canvasProvider.notifier).setTool(tool);
          },
          child: AnimatedContainer(
            duration: MotionDurations.quick,
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: isSelected
                  ? context.accent.withValues(alpha: 0.18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isSelected ? context.accent : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Icon(
              icon,
              size: 18,
              color: isSelected ? context.accent : context.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildColorPicker(BuildContext context) {
    return Semantics(
      label: 'Color picker',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Colour',
              style: TextStyle(
                color: context.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            // Single compact row: 9 quick presets + a custom-colour disk that
            // opens an HSV picker. Wraps if it doesn't fit (palette grows when
            // recent custom colours are added).
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in _penColors) _colorSwatch(context, c),
                _customColorTile(context),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _colorSwatch(BuildContext context, Color c) {
    final isSelected = _selectedColor.toARGB32() == c.toARGB32();
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _selectedColor = c);
        ref.read(canvasProvider.notifier).setColor(c);
      },
      child: AnimatedContainer(
        duration: MotionDurations.quick,
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? context.accent : context.border,
            width: isSelected ? 2.5 : 1,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: c.withValues(alpha: 0.5), blurRadius: 6)]
              : null,
        ),
      ),
    );
  }

  /// "+" tile that pops an HSV / hex colour picker dialog. The selected
  /// custom colour is committed to the canvas provider just like any preset.
  Widget _customColorTile(BuildContext context) {
    final isCustom = !_penColors.any(
      (p) => p.toARGB32() == _selectedColor.toARGB32(),
    );
    return GestureDetector(
      onTap: _openCustomColorPicker,
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // Conic gradient hint that this is the "choose anything" tile.
          gradient: isCustom
              ? null
              : const SweepGradient(
                  colors: [
                    Colors.red,
                    Colors.yellow,
                    Colors.green,
                    Colors.cyan,
                    Colors.blue,
                    Colors.purple,
                    Colors.red,
                  ],
                ),
          color: isCustom ? _selectedColor : null,
          border: Border.all(
            color: isCustom ? context.accent : context.border,
            width: isCustom ? 2.5 : 1,
          ),
        ),
        child: isCustom
            ? null
            : Icon(Icons.add, size: 14, color: context.textPrimary),
      ),
    );
  }

  Future<void> _openCustomColorPicker() async {
    HapticFeedback.selectionClick();
    Color picked = _selectedColor;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surface,
        // Tight dialog — 260px wide, single column. The previous default
        // layout sprawled the saturation box left + hue slider right with
        // significant whitespace; this is more usable in a hover popup.
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        actionsPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        content: SizedBox(
          width: 260,
          child: ColorPicker(
            pickerColor: _selectedColor,
            onColorChanged: (c) => picked = c,
            enableAlpha: false,
            labelTypes: const [],
            // Slightly taller saturation area now that the picker is single-column.
            pickerAreaHeightPercent: 0.85,
            colorPickerWidth: 236,
            displayThumbColor: true,
            paletteType: PaletteType.hsvWithHue,
            pickerAreaBorderRadius: const BorderRadius.all(Radius.circular(6)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Use colour'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed == true) {
      setState(() => _selectedColor = picked);
      ref.read(canvasProvider.notifier).setColor(picked);
    }
  }

  Widget _buildSizePicker(BuildContext context) {
    return Semantics(
      label: 'Stroke width',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Size',
                  style: TextStyle(
                    color: context.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_selectedSize.toStringAsFixed(0)} px',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            // Slider sits in its own subtly-tinted track so it reads as
            // interactive instead of blending into the colour swatches
            // above it (user feedback 2026-05-27).
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: context.surfaceHover.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  // Live preview dot.
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: Center(
                      child: Container(
                        width: _selectedSize.clamp(2.0, 24.0),
                        height: _selectedSize.clamp(2.0, 24.0),
                        decoration: BoxDecoration(
                          color: _selectedColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 3,
                        activeTrackColor: context.accent,
                        inactiveTrackColor: context.border,
                        thumbColor: context.accent,
                        overlayColor: context.accent.withValues(alpha: 0.15),
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                      ),
                      child: Slider(
                        value: _selectedSize.clamp(1.0, 48.0),
                        min: 1,
                        max: 48,
                        divisions: 47,
                        onChanged: (v) {
                          setState(() => _selectedSize = v);
                          ref.read(canvasProvider.notifier).setStrokeWidth(v);
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        children: [
          // Single primary action: "Add image". The destructive Clear
          // moved out of the drawing menu into a confirmed corner
          // button on the lounge so a misclick can't wipe everyone's
          // drawings (image #39 feedback).
          Tooltip(
            message: 'Add an image to the canvas',
            child: SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () async {
                  HapticFeedback.lightImpact();
                  await _pickAndAddImage(context);
                  if (mounted) widget.onRequestClose?.call();
                },
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                label: const Text('Add image'),
                style: TextButton.styleFrom(
                  foregroundColor: context.accent,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
          // Scoped clear: wipes only THIS user's drawings + images from
          // the current session, leaves everyone else's content. The
          // global "Clear board" lives in the lounge corner controls and
          // still asks for confirmation (image #39 feedback).
          Tooltip(
            message: 'Clear only your strokes and images',
            child: SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () {
                  HapticFeedback.selectionClick();
                  ref.read(canvasProvider.notifier).clearMyDrawings();
                },
                icon: const Icon(Icons.cleaning_services_outlined, size: 14),
                label: const Text('Clear my drawings'),
                style: TextButton.styleFrom(
                  foregroundColor: context.textSecondary,
                  textStyle: const TextStyle(fontSize: 11),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          // Icon-only export row. Three text labels at this menu width
          // wrapped onto two lines ("PN G", "Sav e", "Loa d") — tooltips
          // carry the affordance instead.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ExportIconButton(
                icon: Icons.image_outlined,
                tooltip: 'Export canvas as PNG',
                onTap: () => _exportPng(context),
              ),
              const SizedBox(width: 12),
              _ExportIconButton(
                icon: Icons.save_alt_outlined,
                tooltip: 'Save snapshot to JSON',
                onTap: () => _exportJson(context),
              ),
              const SizedBox(width: 12),
              _ExportIconButton(
                icon: Icons.upload_file_outlined,
                tooltip: 'Load snapshot from JSON',
                onTap: () => _importJson(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Save [bytes] under [suggestedName]. On web, file_picker writes the file
  /// itself via a browser download; on native it only returns a path and we
  /// write the bytes ourselves (see services/export_service.dart #740).
  Future<String?> _saveBytes({
    required Uint8List bytes,
    required String suggestedName,
    required String dialogTitle,
    required List<String> allowedExtensions,
  }) async {
    if (kIsWeb) {
      return FilePicker.saveFile(
        dialogTitle: dialogTitle,
        fileName: suggestedName,
        type: FileType.custom,
        allowedExtensions: allowedExtensions,
        bytes: bytes,
      );
    }
    final path = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: suggestedName,
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
    );
    if (path == null) return null;
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<void> _exportPng(BuildContext ctx) async {
    HapticFeedback.lightImpact();
    try {
      final bytes = await CanvasExportService.capturePng(voiceCanvasRepaintKey);
      final path = await _saveBytes(
        bytes: bytes,
        suggestedName:
            'voice-canvas-${DateTime.now().millisecondsSinceEpoch}.png',
        dialogTitle: 'Export canvas as PNG',
        allowedExtensions: const ['png'],
      );
      if (!ctx.mounted) return;
      ToastService.show(
        ctx,
        path == null ? 'Export cancelled.' : 'Canvas exported.',
        type: path == null ? ToastType.info : ToastType.success,
      );
    } catch (e) {
      if (!ctx.mounted) return;
      ToastService.show(ctx, 'PNG export failed: $e', type: ToastType.error);
    }
    if (mounted) widget.onRequestClose?.call();
  }

  Future<void> _exportJson(BuildContext ctx) async {
    HapticFeedback.lightImpact();
    try {
      final json = CanvasExportService.encodeJson(ref.read(canvasProvider));
      final bytes = Uint8List.fromList(utf8.encode(json));
      final path = await _saveBytes(
        bytes: bytes,
        suggestedName:
            'voice-canvas-${DateTime.now().millisecondsSinceEpoch}.json',
        dialogTitle: 'Save canvas snapshot',
        allowedExtensions: const ['json'],
      );
      if (!ctx.mounted) return;
      ToastService.show(
        ctx,
        path == null ? 'Save cancelled.' : 'Snapshot saved.',
        type: path == null ? ToastType.info : ToastType.success,
      );
    } catch (e) {
      if (!ctx.mounted) return;
      ToastService.show(ctx, 'Save failed: $e', type: ToastType.error);
    }
    if (mounted) widget.onRequestClose?.call();
  }

  Future<void> _importJson(BuildContext ctx) async {
    HapticFeedback.lightImpact();
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: 'Load canvas snapshot',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        if (mounted) widget.onRequestClose?.call();
        return;
      }
      final bytes = result.files.first.bytes;
      if (bytes == null) {
        if (!ctx.mounted) return;
        ToastService.show(
          ctx,
          'Could not read the snapshot file.',
          type: ToastType.error,
        );
        return;
      }
      final decoded = CanvasExportService.decodeJson(utf8.decode(bytes));
      ref
          .read(canvasProvider.notifier)
          .importSnapshot(strokes: decoded.strokes, images: decoded.images);
      if (!ctx.mounted) return;
      ToastService.show(ctx, 'Snapshot loaded.', type: ToastType.success);
    } catch (e) {
      if (!ctx.mounted) return;
      ToastService.show(ctx, 'Load failed: $e', type: ToastType.error);
    }
    if (mounted) widget.onRequestClose?.call();
  }

  /// Open the system file picker to select an image and add it to the canvas.
  Future<void> _pickAndAddImage(BuildContext ctx) async {
    // Capture widget/ref values before any await so they remain valid if the
    // state is disposed while the file picker or upload is in progress.
    final conversationId = widget.conversationId;
    final serverUrl = ref.read(serverUrlProvider);
    try {
      final pickedFile = await _pickImageFile();
      if (pickedFile == null) return;

      if (conversationId.isEmpty) {
        // ignore: use_build_context_synchronously
        if (ctx.mounted) {
          _showSnackBar(ctx, 'Open a conversation before adding images');
        }
        return;
      }

      final errorMsg = await _uploadImage(
        file: pickedFile,
        conversationId: conversationId,
        serverUrl: serverUrl,
      );
      // ignore: use_build_context_synchronously
      if (errorMsg != null && ctx.mounted) _showSnackBar(ctx, errorMsg);
    } catch (e) {
      debugPrint('[DrawingMenu] pickImage error: $e');
      // ignore: use_build_context_synchronously
      if (ctx.mounted) _showSnackBar(ctx, 'Failed to add image');
    }
  }

  /// Returns the picked file with bytes, or null if the user cancelled or
  /// no bytes were available.
  Future<PlatformFile?> _pickImageFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    return file.bytes == null ? null : file;
  }

  /// Uploads [file] and places the image on the canvas on success.
  /// Returns an error message string on failure, or null on success.
  Future<String?> _uploadImage({
    required PlatformFile file,
    required String conversationId,
    required String serverUrl,
  }) async {
    final ext = file.extension?.toLowerCase() ?? 'png';
    final mimeType = _mimeForExtension(ext);
    final bytes = file.bytes!;

    Future<UploadResult> uploadChunked() async {
      final auth = ref.read(authProvider.notifier);
      final chunked = ChunkedUploadClient(
        tokenGetter: () => auth.currentToken,
        refresher: auth.refreshAccessToken,
      );
      final result = await chunked.uploadBytes(
        bytes: bytes,
        serverUrl: serverUrl,
        mimeType: mimeType,
        filename: file.name,
        conversationId: conversationId,
      );
      return result.toUploadResult();
    }

    final UploadResult uploadResult;
    if (shouldUseChunkedUpload(bytes.length)) {
      uploadResult = await uploadChunked();
    } else {
      final uploader = UploadClient(ref.read(authProvider.notifier));
      final singleShot = await uploader.uploadFile(
        serverUrl: serverUrl,
        path: '/api/media/upload',
        bytes: bytes,
        fileName: file.name,
        mimeType: mimeType,
        extraFields: {'conversation_id': conversationId},
      );
      uploadResult = (!singleShot.ok && singleShot.statusCode == 413)
          ? await uploadChunked()
          : singleShot;
    }
    if (!mounted) return null;

    if (uploadResult.ok) {
      final relUrl = uploadResult.url ?? '';
      final absUrl = relUrl.startsWith('http') ? relUrl : '$serverUrl$relUrl';
      _addImageByUrl(absUrl);
      return null;
    }
    // Upload failed — surface the error so the user can retry.  We no
    // longer fall back to a local-only preview because that copy never
    // synced to other participants and led to a confusing experience.
    return 'Image upload failed; please try again';
  }

  void _showSnackBar(BuildContext ctx, String message) {
    ToastService.show(ctx, message, type: ToastType.error);
  }

  void _addImageByUrl(String url) {
    if (!mounted) return;
    // Broadcast via canvasProvider only — local _canvas?.addImageFromUrl caused a "stuck twin" (#752).
    // CanvasImage coords are ABSOLUTE canvas pixels, not 0..1 fractions. The
    // old normalized 0.375/0.25 values placed a sub-pixel image in the
    // top-left corner (invisible to the uploader; rescaled by the legacy
    // migration on remotes) — i.e. "add image did nothing". Spawn a
    // quarter-board-sized image dead-centre, matching the paste path.
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

  static String _mimeForExtension(String ext) {
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      default:
        return 'image/png';
    }
  }
}

/// Compact icon-only button used for the canvas snapshot row. Carries the
/// affordance label as a tooltip so the menu doesn't have to grow wider to
/// fit "Save / Load / PNG" text on every locale + density combo.
class _ExportIconButton extends StatelessWidget {
  const _ExportIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        radius: 22,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 18, color: context.textSecondary),
        ),
      ),
    );
  }
}
