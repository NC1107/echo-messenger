// ignore_for_file: invalid_use_of_protected_member

part of '../../chat_input_bar.dart';

/// Media-picker plumbing: bottom-sheet attach menu on mobile, gallery /
/// camera picks via the `file_pickers.dart` helpers, and the inline / overlay
/// picker show-hide flow.
extension _MediaPicker on ChatInputBarState {
  void _showMobileAttachMenu() {
    showEchoBottomSheet<void>(
      context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AttachOption(
              icon: Icons.photo_library_outlined,
              label: 'Photos & Videos',
              onTap: () {
                Navigator.pop(ctx);
                _pickImageFromGallery();
              },
            ),
            AttachOption(
              icon: Icons.camera_alt_outlined,
              label: 'Camera',
              onTap: () {
                Navigator.pop(ctx);
                _pickImageFromCamera();
              },
            ),
            AttachOption(
              icon: Icons.insert_drive_file_outlined,
              label: 'File',
              onTap: () {
                Navigator.pop(ctx);
                _pickFile();
              },
            ),
            AttachOption(
              icon: Icons.text_format,
              label: _showFormatToolbarOnMobile
                  ? 'Hide formatting'
                  : 'Formatting',
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _showFormatToolbarOnMobile = !_showFormatToolbarOnMobile;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImageFromGallery() => pickers.pickImageFromGallery(
    context: context,
    mounted: () => mounted,
    isPicking: () => _isPickingFile,
    setIsPicking: (v) => _isPickingFile = v,
    stage:
        ({
          required List<int> bytes,
          required String fileName,
          required String mimeType,
          required String ext,
        }) => _setPendingAttachment(
          bytes: bytes,
          fileName: fileName,
          mimeType: mimeType,
          ext: ext,
        ),
    sendImmediately: _sendFileImmediately,
  );

  Future<void> _pickImageFromCamera() => pickers.pickImageFromCamera(
    context: context,
    mounted: () => mounted,
    isPicking: () => _isPickingFile,
    setIsPicking: (v) => _isPickingFile = v,
    stage:
        ({
          required List<int> bytes,
          required String fileName,
          required String mimeType,
          required String ext,
        }) => _setPendingAttachment(
          bytes: bytes,
          fileName: fileName,
          mimeType: mimeType,
          ext: ext,
        ),
  );

  /// Toggles the inline (mobile) or overlay (desktop) media picker. Shared
  /// callback wired into [MediaPickerToggle] from `_buildInputRow`.
  void _toggleMediaPicker(bool isMobileLayout) {
    if (isMobileLayout) {
      if (_showInlinePicker) {
        setState(() => _showInlinePicker = false);
        _inputFocusNode.requestFocus();
      } else {
        _inputFocusNode.unfocus();
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          if (mounted) setState(() => _showInlinePicker = true);
        });
      }
      widget.onMediaPickerChanged?.call();
    } else {
      setState(() => _showMediaPicker = !_showMediaPicker);
      widget.onMediaPickerChanged?.call();
      if (!_showMediaPicker) {
        _inputFocusNode.requestFocus();
      }
    }
  }

  /// Inserts [emojiStr] at the current cursor position in the text field.
  void _insertEmoji(String emojiStr) {
    final text = _messageController.text;
    final selection = _messageController.selection;
    final cursorPos = selection.baseOffset >= 0
        ? selection.baseOffset
        : text.length;
    final newText =
        text.substring(0, cursorPos) + emojiStr + text.substring(cursorPos);
    _messageController.text = newText;
    _messageController.selection = TextSelection.collapsed(
      offset: cursorPos + emojiStr.length,
    );
  }

  /// Handle a photo selected from the camera roll gallery.
  Future<void> _handlePhotoSelected(
    File file,
    String fileName,
    String mimeType,
  ) async {
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final ext = fileName.split('.').last.toLowerCase();
    setState(() => _showInlinePicker = false);
    _setPendingAttachment(
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
      ext: ext,
    );
  }
}
