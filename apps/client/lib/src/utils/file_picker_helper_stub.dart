import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

class PickedFile {
  final Uint8List bytes;
  final String name;
  final String? extension;

  const PickedFile({
    required this.bytes,
    required this.name,
    this.extension,
  });
}

Future<PickedFile?> pickAnyFile() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.any,
    allowMultiple: false,
    withData: true,
  );
  if (result == null || result.files.isEmpty) return null;
  final file = result.files.first;
  if (file.bytes == null) return null;
  return PickedFile(
    bytes: file.bytes!,
    name: file.name,
    extension: file.extension?.toLowerCase(),
  );
}

Future<PickedFile?> pickImageFile() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.image,
    allowMultiple: false,
    withData: true,
  );
  if (result == null || result.files.isEmpty) return null;
  final file = result.files.first;
  if (file.bytes == null) return null;
  return PickedFile(
    bytes: file.bytes!,
    name: file.name,
    extension: file.extension?.toLowerCase(),
  );
}
