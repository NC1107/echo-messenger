// ignore_for_file: invalid_use_of_protected_member

part of '../../chat_input_bar.dart';

/// Pending-attachment lifecycle: staging, upload-with-auth-retry,
/// clipboard paste, annotate, drop-immediately send, and the file-picker
/// glue that wires the `file_pickers.dart` helpers back to this State.
extension _Attachments on ChatInputBarState {
  /// Stage [bytes] as a new pending attachment and kick off its upload.
  /// Multiple calls accumulate — the strip shows N chips for N picks until
  /// the user sends or cancels each.
  void _setPendingAttachment({
    required List<int> bytes,
    required String fileName,
    required String mimeType,
    required String ext,
  }) {
    final attachment = PendingAttachment(
      bytes: Uint8List.fromList(bytes),
      fileName: fileName,
      mimeType: mimeType,
      ext: ext,
      sizeBytes: bytes.length,
    );
    setState(() => _pendingAttachments.add(attachment));
    _startAttachmentUploadFor(attachment);
  }

  /// Cancel and remove a single staged attachment. Safe to call before the
  /// upload completes — the [cancelled] flag short-circuits the
  /// success-path setState in [_startAttachmentUploadFor].
  void _removePendingAttachment(PendingAttachment attachment) {
    if (!_pendingAttachments.contains(attachment)) return;
    attachment.cancelled = true;
    setState(() => _pendingAttachments.remove(attachment));
    attachment.dispose();
  }

  /// Open the [ImageAnnotationEditor] on top of the composer. When the user
  /// confirms, the original attachment is cancelled and replaced with a new
  /// pending attachment whose bytes are the annotated PNG (#908). The new
  /// attachment goes through the regular upload + send path — the
  /// encrypt/wire flow is untouched.
  Future<void> _annotatePendingAttachment(PendingAttachment attachment) async {
    final bytes = attachment.bytes;
    if (bytes == null) return; // External-URL attachments can't be annotated.

    final navigator = Navigator.of(context);
    Uint8List? annotated;
    await navigator.push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ImageAnnotationEditor(
          imageBytes: bytes,
          onConfirm: (Uint8List pngBytes) {
            annotated = pngBytes;
            Navigator.of(navigator.context).maybePop();
          },
        ),
      ),
    );
    if (!mounted || annotated == null) return;

    // Replace the original chip. Strip the source extension and force PNG
    // since the rasterised output is always PNG-encoded.
    final originalName = attachment.fileName;
    final dot = originalName.lastIndexOf('.');
    final stem = dot > 0 ? originalName.substring(0, dot) : originalName;
    final newName = '$stem-annotated.png';

    _removePendingAttachment(attachment);
    _setPendingAttachment(
      bytes: annotated!,
      fileName: newName,
      mimeType: 'image/png',
      ext: 'png',
    );
  }

  /// Stage an external-URL attachment (e.g. picked from the GIF browser).
  /// No upload is performed — the URL is used as-is on send.
  void _setPendingExternalAttachment({
    required String url,
    required String fileName,
    required String mimeType,
    required String ext,
  }) {
    final attachment = PendingAttachment(
      bytes: null,
      fileName: fileName,
      mimeType: mimeType,
      ext: ext,
      sizeBytes: 0,
      uploadedUrl: url,
    );
    setState(() => _pendingAttachments.add(attachment));
  }

  /// Drop all staged attachments. Called after a successful send.
  void _clearAllPendingAttachments() {
    if (_pendingAttachments.isEmpty) return;
    final toDispose = List<PendingAttachment>.from(_pendingAttachments);
    setState(() => _pendingAttachments.clear());
    for (final att in toDispose) {
      att.dispose();
    }
  }

  Future<void> _startAttachmentUploadFor(PendingAttachment att) async {
    if (att.isExternalUrl) return; // already has a URL (e.g. GIF picker).
    final bytes = att.bytes!;
    final serverUrl = ref.read(serverUrlProvider);
    try {
      final result = await _uploadWithAuthRetry(
        serverUrl: serverUrl,
        bytes: bytes,
        fileName: att.fileName,
        mimeType: att.mimeType,
        onProgress: (sent, total) {
          if (att.cancelled || total <= 0) return;
          att.progress.value = (sent / total).clamp(0.0, 1.0);
        },
      );
      if (!mounted || att.cancelled) return;

      if (result != null) {
        setState(() {
          att.uploadedUrl = result;
          att.isUploading = false;
          att.progress.value = 1.0;
        });
        _inputFocusNode.requestFocus();
      } else {
        if (mounted) {
          ToastService.show(
            context,
            'Upload failed: ${att.fileName}',
            type: ToastType.error,
          );
        }
        _removePendingAttachment(att);
      }
    } catch (e) {
      if (!mounted || att.cancelled) return;
      ToastService.show(
        context,
        'Upload failed: ${att.fileName}',
        type: ToastType.error,
      );
      _removePendingAttachment(att);
    }
  }

  /// Upload media with automatic 401→token-refresh→retry via [UploadClient].
  ///
  /// Returns the server-assigned URL on success, or null on failure.
  Future<String?> _uploadWithAuthRetry({
    required String serverUrl,
    required List<int> bytes,
    required String fileName,
    required String mimeType,
    void Function(int sent, int total)? onProgress,
  }) async {
    // If the user has the "preserve original filenames" privacy toggle off,
    // upload the file under a generic name keyed off the extension. The file
    // contents are unchanged.
    final preserve = await readPreserveOriginalFilenames();
    final uploadFileName = preserve ? fileName : genericFilename(fileName);

    // Files above the chunked-upload threshold go through the resumable
    // PATCH pipeline (#556).  Cloudflare's edge cap is 100 MB; the chunked
    // path streams 5 MB chunks server-side so it can ferry files multiples
    // of that without ever pinning the whole payload in server RAM.
    Future<UploadResult> uploadChunked() async {
      final auth = ref.read(authProvider.notifier);
      final chunked = ChunkedUploadClient(
        tokenGetter: () => auth.currentToken,
        refresher: auth.refreshAccessToken,
      );
      final chunkedResult = await chunked.uploadBytes(
        bytes: bytes,
        serverUrl: serverUrl,
        mimeType: mimeType,
        filename: uploadFileName,
        conversationId: widget.conversation.id,
        onProgress: onProgress,
      );
      return chunkedResult.toUploadResult();
    }

    final UploadResult result;
    if (bytes.length >= kChunkedUploadThresholdBytes) {
      result = await uploadChunked();
    } else {
      final uploader = UploadClient(ref.read(authProvider.notifier));
      final singleShotResult = await uploader.uploadFile(
        serverUrl: serverUrl,
        path: '/api/media/upload',
        bytes: bytes,
        fileName: uploadFileName,
        mimeType: mimeType,
        extraFields: {'conversation_id': widget.conversation.id},
        onProgress: onProgress,
      );
      if (!singleShotResult.ok && singleShotResult.statusCode == 413) {
        result = await uploadChunked();
      } else {
        result = singleShotResult;
      }
    }

    if (result.ok) {
      // Pre-populate the dimension cache so ImageAttachment can reserve the
      // correct aspect-ratio placeholder on first render, before bytes arrive.
      final url = result.url;
      final w = result.width;
      final h = result.height;
      if (url != null && w != null && h != null) {
        cacheImageDimensions(url, w, h);
      }
      return url;
    }

    if (mounted && !result.ok) {
      final error = result.errorMessage?.trim();
      ToastService.show(
        context,
        (error != null && error.isNotEmpty)
            ? 'Upload failed: $error'
            : 'Upload failed (${result.statusCode})',
        type: ToastType.error,
      );
    }
    return null;
  }

  Future<void> _pasteImageFromClipboard() async {
    final image = await readImageFromClipboard();
    if (image == null) return;
    if (!mounted) return;

    _setPendingAttachment(
      bytes: image.bytes,
      fileName: image.fileName,
      mimeType: image.mimeType,
      ext: extensionFromMime(image.mimeType),
    );
  }

  /// Handle Ctrl+V: read clipboard text and insert at cursor, bypassing the
  /// browser's native paste context menu that CanvasKit shows by default.
  /// Also tries image paste in parallel for clipboard images.
  Future<void> _handlePaste() async {
    // Try image paste (non-blocking)
    if (!_isEditing) {
      _pasteImageFromClipboard();
    }

    // Read text from clipboard and insert at cursor
    final data = await Clipboard.getData('text/plain');
    if (data?.text == null || data!.text!.isEmpty) return;
    if (!mounted) return;

    final text = data.text!;
    final selection = _messageController.selection;
    final currentText = _messageController.text;

    if (selection.isValid) {
      final newText = currentText.replaceRange(
        selection.start,
        selection.end,
        text,
      );
      _messageController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: selection.start + text.length,
        ),
      );
    } else {
      _messageController.value = TextEditingValue(
        text: currentText + text,
        selection: TextSelection.collapsed(
          offset: currentText.length + text.length,
        ),
      );
    }

    _onInputChanged(_messageController.text);
  }

  /// Upload [bytes] and immediately send the result as a message.
  /// Used for the 2nd..Nth files when multiple are selected at once.
  Future<void> _sendFileImmediately({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required String ext,
  }) async {
    final serverUrl = ref.read(serverUrlProvider);
    final url = await _uploadWithAuthRetry(
      serverUrl: serverUrl,
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeType,
    );
    if (!mounted || url == null) return;
    final marker = buildMediaMarker(extension: ext, url: url);
    await _doSend(marker);
  }

  Future<void> _pickFile() => pickers.pickFile(
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
}
