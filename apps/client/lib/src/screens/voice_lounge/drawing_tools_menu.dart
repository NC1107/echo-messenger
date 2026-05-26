/// Drawing tools popup menu used by the floating dock's draw submenu.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  static final _rng = math.Random();

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

  static const _penSizes = [2.0, 4.0, 6.0, 10.0, 16.0];

  @override
  void initState() {
    super.initState();
    // Hydrate from the provider so the menu opens with the current selection.
    final canvas = ref.read(canvasProvider);
    _selectedTool = canvas.selectedTool == CanvasTool.eraser
        ? CanvasTool.eraser
        : CanvasTool.pen;
    _selectedColor = canvas.currentColor;
    _selectedSize = canvas.strokeWidth;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 280,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildToolSelector(context),
          if (_selectedTool == CanvasTool.pen) ...[
            const Divider(height: 1),
            _buildColorPicker(context),
            const SizedBox(height: 4),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          _toolChip(context, Icons.edit, 'Draw', CanvasTool.pen),
          const SizedBox(width: 8),
          _toolChip(context, Icons.auto_fix_high, 'Erase', CanvasTool.eraser),
        ],
      ),
    );
  }

  Widget _buildColorPicker(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(
            'Color',
            style: TextStyle(
              color: context.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: GridView.count(
            crossAxisCount: 5,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.0,
            children: _penColors.map((c) => _colorSwatch(context, c)).toList(),
          ),
        ),
      ],
    );
  }

  Widget _colorSwatch(BuildContext context, Color c) {
    final isSelected = _selectedColor == c;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _selectedColor = c);
        ref.read(canvasProvider.notifier).setColor(c);
      },
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: AnimatedContainer(
            duration: MotionDurations.quick,
            width: isSelected ? 24 : 20,
            height: isSelected ? 24 : 20,
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
        ),
      ),
    );
  }

  Widget _buildSizePicker(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(
            'Size',
            style: TextStyle(
              color: context.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: _penSizes.map((s) => _sizeChip(context, s)).toList(),
          ),
        ),
      ],
    );
  }

  Widget _sizeChip(BuildContext context, double s) {
    final isSelected = _selectedSize == s;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _selectedSize = s);
          ref.read(canvasProvider.notifier).setStrokeWidth(s);
        },
        child: AnimatedContainer(
          duration: MotionDurations.quick,
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isSelected
                ? context.accent.withValues(alpha: 0.12)
                : Colors.transparent,
            border: Border.all(
              color: isSelected ? context.accent : context.border,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Center(
            child: Container(
              width: s.clamp(4.0, 16.0),
              height: s.clamp(4.0, 16.0),
              decoration: BoxDecoration(
                color: isSelected ? context.accent : context.textPrimary,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () async {
                    HapticFeedback.lightImpact();
                    await _pickAndAddImage(context);
                    if (mounted) widget.onRequestClose?.call();
                  },
                  icon: const Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 16,
                  ),
                  label: const Text('Image'),
                  style: TextButton.styleFrom(
                    foregroundColor: context.accent,
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: TextButton.icon(
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    ref.read(canvasProvider.notifier).clearDrawing();
                    widget.onRequestClose?.call();
                  },
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Clear'),
                  style: TextButton.styleFrom(
                    foregroundColor: EchoTheme.danger,
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
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
    final img = CanvasImage(
      id: newCanvasId(),
      url: url,
      x: 0.2 + _rng.nextDouble() * 0.3,
      y: 0.2 + _rng.nextDouble() * 0.3,
      width: 0.25,
      height: 0.25,
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

  Widget _toolChip(
    BuildContext context,
    IconData icon,
    String label,
    CanvasTool tool,
  ) {
    final isSelected = _selectedTool == tool;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _selectedTool = tool);
          ref.read(canvasProvider.notifier).setTool(tool);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? context.accent.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? context.accent : context.border,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected ? context.accent : context.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? context.accent : context.textPrimary,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
