import 'dart:io' show File;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';

import '../../services/toast_service.dart';
import 'upload_helpers.dart';

typedef StageAttachmentFn =
    void Function({
      required List<int> bytes,
      required String fileName,
      required String mimeType,
      required String ext,
    });

typedef SendFileImmediatelyFn =
    Future<void> Function({
      required Uint8List bytes,
      required String fileName,
      required String mimeType,
      required String ext,
    });

/// Discord-style file pick: single file → preview-and-caption flow,
/// multiple files → upload + send each as a separate message.
Future<void> pickFile({
  required BuildContext context,
  required bool Function() mounted,
  required bool Function() isPicking,
  required void Function(bool) setIsPicking,
  required StageAttachmentFn stage,
  required SendFileImmediatelyFn sendImmediately,
}) => _pickAndDispatch((
  context: context,
  mounted: mounted,
  isPicking: isPicking,
  setIsPicking: setIsPicking,
  stage: stage,
  sendImmediately: sendImmediately,
  type: FileType.any,
  errorPrefix: 'File pick',
));

/// Mobile gallery picker — same multi/single semantics as [pickFile] but
/// scoped to `FileType.media`.
Future<void> pickImageFromGallery({
  required BuildContext context,
  required bool Function() mounted,
  required bool Function() isPicking,
  required void Function(bool) setIsPicking,
  required StageAttachmentFn stage,
  required SendFileImmediatelyFn sendImmediately,
}) => _pickAndDispatch((
  context: context,
  mounted: mounted,
  isPicking: isPicking,
  setIsPicking: setIsPicking,
  stage: stage,
  sendImmediately: sendImmediately,
  type: FileType.media,
  errorPrefix: 'Pick',
));

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Reads raw bytes for [file], falling back to a path read on non-web mobile
/// when `withData: true` yields null (e.g. large files / content URIs).
Future<Uint8List?> _readFileBytes(PlatformFile file) async {
  if (file.bytes != null) return file.bytes;
  if (file.path == null || kIsWeb) return null;
  try {
    return await File(file.path!).readAsBytes();
  } catch (e) {
    debugPrint('[ChatInput] Failed to read file from path: $e');
    return null;
  }
}

/// Returns `(ext, mimeType)` for [file].
(String, String) _resolveMime(PlatformFile file) {
  final ext = (file.extension ?? '').toLowerCase();
  final mime = kMimeTypes[ext] ?? ['application', kOctetStream];
  return (ext, '${mime[0]}/${mime[1]}');
}

/// Validates size, resolves bytes + mime, then either stages (single-pick) or
/// sends immediately (multi-pick). Returns `true` when a file was successfully
/// handled so the caller can count successes.
Future<bool> _dispatchFile({
  required BuildContext context,
  required PlatformFile file,
  required bool isMulti,
  required StageAttachmentFn stage,
  required SendFileImmediatelyFn sendImmediately,
}) async {
  if (file.size > kMaxUploadBytes) {
    if (context.mounted) {
      ToastService.show(
        context,
        '${file.name} is ${formatBytes(file.size)} — limit is '
        '${formatBytes(kMaxUploadBytes)}',
        type: ToastType.error,
      );
    }
    return false;
  }

  final bytes = await _readFileBytes(file);
  if (bytes == null) {
    if (context.mounted) {
      ToastService.show(
        context,
        'Could not read file: ${file.name}',
        type: ToastType.error,
      );
    }
    return false;
  }

  final (ext, mimeType) = _resolveMime(file);

  if (!isMulti) {
    stage(bytes: bytes, fileName: file.name, mimeType: mimeType, ext: ext);
    return true;
  }

  try {
    await sendImmediately(
      bytes: bytes,
      fileName: file.name,
      mimeType: mimeType,
      ext: ext,
    );
    return true;
  } catch (e) {
    debugPrint('[ChatInput] Send failed for ${file.name}: $e');
    if (context.mounted) {
      ToastService.show(
        context,
        'Failed to send ${file.name}',
        type: ToastType.error,
      );
    }
    return false;
  }
}

typedef _PickAndDispatchParams = ({
  BuildContext context,
  bool Function() mounted,
  bool Function() isPicking,
  void Function(bool) setIsPicking,
  StageAttachmentFn stage,
  SendFileImmediatelyFn sendImmediately,
  FileType type,
  String errorPrefix,
});

Future<void> _pickAndDispatch(_PickAndDispatchParams params) async {
  if (params.isPicking()) return;
  params.setIsPicking(true);
  try {
    await _runPickAndDispatch(params);
  } catch (e) {
    _showPickError(params.context, '${params.errorPrefix} error: $e');
  } finally {
    params.setIsPicking(false);
  }
}

Future<void> _runPickAndDispatch(_PickAndDispatchParams params) async {
  final context = params.context;
  final result = await FilePicker.pickFiles(
    type: params.type,
    allowMultiple: true,
    withData: true,
  );
  if (result == null || result.files.isEmpty) return;
  if (!params.mounted() || !context.mounted) return;
  await _dispatchPickedFiles(context, params, result.files);
}

void _showPickError(BuildContext context, String message) {
  if (!context.mounted) return;
  ToastService.show(context, message, type: ToastType.error);
}

/// Dispatches a previously-picked list of files, surfacing toast feedback
/// for multi-file sends. Extracted from [_pickAndDispatch] to keep its
/// cognitive complexity below SonarCloud's threshold.
Future<void> _dispatchPickedFiles(
  BuildContext context,
  _PickAndDispatchParams params,
  List<PlatformFile> files,
) async {
  // Single pick → preview flow (caption + send). Multi pick → send all
  // immediately as separate messages; mixing the two creates races where
  // the user may interact with the pending preview while the rest are
  // still uploading in the background.
  final isMulti = files.length > 1;
  if (isMulti && context.mounted) {
    ToastService.show(
      context,
      'Sending ${files.length} files...',
      type: ToastType.info,
    );
  }

  var sentCount = 0;
  for (final file in files) {
    if (!context.mounted) break;
    final ok = await _dispatchFile(
      context: context,
      file: file,
      isMulti: isMulti,
      stage: params.stage,
      sendImmediately: params.sendImmediately,
    );
    if (ok) sentCount++;
  }

  if (isMulti && context.mounted && sentCount < files.length) {
    final failed = files.length - sentCount;
    ToastService.show(
      context,
      '$failed of ${files.length} failed to send',
      type: ToastType.error,
    );
  }
}

/// Camera-only single-shot picker.
Future<void> pickImageFromCamera({
  required BuildContext context,
  required bool Function() mounted,
  required bool Function() isPicking,
  required void Function(bool) setIsPicking,
  required StageAttachmentFn stage,
}) async {
  if (isPicking()) return;
  setIsPicking(true);
  try {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted()) return;
    final file = result.files.first;
    final bytes = await _readFileBytes(file);
    if (bytes == null) return;
    final ext = (file.extension ?? 'jpg').toLowerCase();
    stage(
      bytes: bytes,
      fileName: file.name,
      mimeType: 'image/${ext == 'jpg' ? 'jpeg' : ext}',
      ext: ext,
    );
  } catch (e) {
    if (!context.mounted) return;
    ToastService.show(context, 'Camera error: $e', type: ToastType.error);
  } finally {
    setIsPicking(false);
  }
}
