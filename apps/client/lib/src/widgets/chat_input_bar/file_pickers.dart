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
}) async {
  if (isPicking()) return;
  setIsPicking(true);
  try {
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted()) return;

    // Single pick → preview flow (caption + send). Multi pick → send all
    // immediately as separate messages; mixing the two creates races where
    // the user may interact with the pending preview while the rest are
    // still uploading in the background.
    final isMulti = result.files.length > 1;
    if (isMulti && context.mounted) {
      ToastService.show(
        context,
        'Sending ${result.files.length} files...',
        type: ToastType.info,
      );
    }

    var sentCount = 0;
    for (final file in result.files) {
      if (file.size > kMaxUploadBytes) {
        if (context.mounted) {
          ToastService.show(
            context,
            '${file.name} is ${formatBytes(file.size)} — limit is '
            '${formatBytes(kMaxUploadBytes)}',
            type: ToastType.error,
          );
        }
        continue;
      }

      // On mobile, withData:true may still yield null bytes for larger files
      // or certain content URIs. Fall back to reading from the file path.
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null && !kIsWeb) {
        try {
          bytes = await File(file.path!).readAsBytes();
        } catch (e) {
          debugPrint('[ChatInput] Failed to read file from path: $e');
        }
      }

      if (bytes == null) {
        if (context.mounted) {
          ToastService.show(
            context,
            'Could not read file: ${file.name}',
            type: ToastType.error,
          );
        }
        continue;
      }

      final ext = (file.extension ?? '').toLowerCase();
      final mime = kMimeTypes[ext] ?? ['application', kOctetStream];
      final mimeType = '${mime[0]}/${mime[1]}';

      if (isMulti) {
        try {
          await sendImmediately(
            bytes: bytes,
            fileName: file.name,
            mimeType: mimeType,
            ext: ext,
          );
          sentCount++;
        } catch (e) {
          debugPrint('[ChatInput] Send failed for ${file.name}: $e');
          if (context.mounted) {
            ToastService.show(
              context,
              'Failed to send ${file.name}',
              type: ToastType.error,
            );
          }
        }
      } else {
        stage(bytes: bytes, fileName: file.name, mimeType: mimeType, ext: ext);
      }
    }
    if (isMulti && context.mounted && sentCount < result.files.length) {
      final failed = result.files.length - sentCount;
      ToastService.show(
        context,
        '$failed of ${result.files.length} failed to send',
        type: ToastType.error,
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    ToastService.show(context, 'File pick error: $e', type: ToastType.error);
  } finally {
    setIsPicking(false);
  }
}

/// Mobile gallery picker — same multi/single semantics as [pickFile] but
/// scoped to `FileType.media`.
Future<void> pickImageFromGallery({
  required BuildContext context,
  required bool Function() mounted,
  required bool Function() isPicking,
  required void Function(bool) setIsPicking,
  required StageAttachmentFn stage,
  required SendFileImmediatelyFn sendImmediately,
}) async {
  if (isPicking()) return;
  setIsPicking(true);
  try {
    final result = await FilePicker.pickFiles(
      type: FileType.media,
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted()) return;

    final isMulti = result.files.length > 1;
    if (isMulti && context.mounted) {
      ToastService.show(
        context,
        'Sending ${result.files.length} files...',
        type: ToastType.info,
      );
    }

    var sentCount = 0;
    for (final file in result.files) {
      if (file.size > kMaxUploadBytes) {
        if (context.mounted) {
          ToastService.show(
            context,
            '${file.name} is ${formatBytes(file.size)} — limit is '
            '${formatBytes(kMaxUploadBytes)}',
            type: ToastType.error,
          );
        }
        continue;
      }

      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null && !kIsWeb) {
        try {
          bytes = await File(file.path!).readAsBytes();
        } catch (_) {}
      }
      if (bytes == null) continue;

      final ext = (file.extension ?? '').toLowerCase();
      final mime = kMimeTypes[ext] ?? ['application', kOctetStream];
      final mimeType = '${mime[0]}/${mime[1]}';

      if (isMulti) {
        try {
          await sendImmediately(
            bytes: bytes,
            fileName: file.name,
            mimeType: mimeType,
            ext: ext,
          );
          sentCount++;
        } catch (e) {
          debugPrint('[ChatInput] Send failed for ${file.name}: $e');
          if (context.mounted) {
            ToastService.show(
              context,
              'Failed to send ${file.name}',
              type: ToastType.error,
            );
          }
        }
      } else {
        stage(bytes: bytes, fileName: file.name, mimeType: mimeType, ext: ext);
      }
    }
    if (isMulti && context.mounted && sentCount < result.files.length) {
      final failed = result.files.length - sentCount;
      ToastService.show(
        context,
        '$failed of ${result.files.length} failed to send',
        type: ToastType.error,
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    ToastService.show(context, 'Pick error: $e', type: ToastType.error);
  } finally {
    setIsPicking(false);
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
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null && !kIsWeb) {
      try {
        bytes = await File(file.path!).readAsBytes();
      } catch (_) {}
    }
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
