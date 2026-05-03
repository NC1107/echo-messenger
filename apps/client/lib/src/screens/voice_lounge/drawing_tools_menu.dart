/// Drawing tools popup menu used by the floating dock's draw submenu.
library;

import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/canvas_models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/canvas_provider.dart';
import '../../providers/server_url_provider.dart';
import '../../services/upload_client.dart';
import '../../theme/echo_theme.dart';
import '../../utils/canvas_utils.dart';

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
      width: 200,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tool selection
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                _toolChip(context, Icons.edit, 'Draw', CanvasTool.pen),
                const SizedBox(width: 8),
                _toolChip(
                  context,
                  Icons.auto_fix_high,
                  'Erase',
                  CanvasTool.eraser,
                ),
              ],
            ),
          ),
          if (_selectedTool == CanvasTool.pen) ...[
            const Divider(height: 1),
            // Color picker
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
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _penColors.map((c) {
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
                          duration: const Duration(milliseconds: 120),
                          width: isSelected ? 24 : 20,
                          height: isSelected ? 24 : 20,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSelected
                                  ? context.accent
                                  : context.border,
                              width: isSelected ? 2.5 : 1,
                            ),
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: c.withValues(alpha: 0.5),
                                      blurRadius: 6,
                                    ),
                                  ]
                                : null,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 4),
            const Divider(height: 1),
            // Size picker
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
                children: _penSizes.map((s) {
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
                        duration: const Duration(milliseconds: 120),
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
                              color: isSelected
                                  ? context.accent
                                  : context.textPrimary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
          const Divider(height: 12),
          // Image + Clear
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
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
          ),
        ],
      ),
    );
  }

  /// Open the system file picker to select an image and add it to the canvas.
  Future<void> _pickAndAddImage(BuildContext ctx) async {
    // Capture widget/ref values before any await so they remain valid if the
    // state is disposed while the file picker or upload is in progress.
    final conversationId = widget.conversationId;
    final serverUrl = ref.read(serverUrlProvider);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) return;

      if (conversationId.isEmpty) {
        // No conversation — image add requires a conversation context for
        // the upload + broadcast.  Show a snackbar instead of a local-only
        // preview that wouldn't sync to anyone.
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            const SnackBar(
              content: Text('Open a conversation before adding images'),
            ),
          );
        }
        return;
      }

      final ext = file.extension?.toLowerCase() ?? 'png';
      final mimeType = _mimeForExtension(ext);
      final uploader = UploadClient(ref.read(authProvider.notifier));
      final uploadResult = await uploader.uploadFile(
        serverUrl: serverUrl,
        path: '/api/media/upload',
        bytes: bytes,
        fileName: file.name,
        mimeType: mimeType,
        extraFields: {'conversation_id': conversationId},
      );
      if (!mounted) return;

      if (uploadResult.ok) {
        final relUrl = uploadResult.url ?? '';
        final absUrl = relUrl.startsWith('http') ? relUrl : '$serverUrl$relUrl';
        _addImageByUrl(absUrl);
      } else {
        // Upload failed — surface the error so the user can retry.  We no
        // longer fall back to a local-only preview because that copy never
        // synced to other participants and led to a confusing experience.
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            const SnackBar(
              content: Text('Image upload failed; please try again'),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[DrawingMenu] pickImage error: $e');
      if (ctx.mounted) {
        ScaffoldMessenger.of(
          ctx,
        ).showSnackBar(const SnackBar(content: Text('Failed to add image')));
      }
    }
  }

  void _addImageByUrl(String url) {
    if (!mounted) return;
    // Broadcast via canvasProvider so every participant (including this
    // one, via VoiceCanvas's ref.watch on canvas state) renders the image.
    // Previously also called _canvas?.addImageFromUrl(...) which placed a
    // SECOND copy at canvas-center inside LoungeDrawingCanvas's local
    // _images list -- that copy never broadcast and never moved when the
    // shared one was dragged, producing the "stuck twin" the user
    // reported in #752.
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
