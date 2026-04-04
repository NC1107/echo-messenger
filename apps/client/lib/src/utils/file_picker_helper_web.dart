import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

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

Future<PickedFile?> pickAnyFile() => _pickWebFile('*/*');

Future<PickedFile?> pickImageFile() => _pickWebFile('image/*');

/// Creates a hidden file input, triggers it synchronously within the current
/// user-gesture call stack (required by iOS Safari), and returns the selected
/// file's bytes once the user confirms the picker.
Future<PickedFile?> _pickWebFile(String accept) {
  final completer = Completer<PickedFile?>();
  bool done = false;

  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = accept
    ..style.cssText =
        'position:fixed;top:-100px;left:-100px;width:1px;height:1px;opacity:0;';

  web.document.body?.appendChild(input);

  // Fired when the user selects a file.
  input.addEventListener(
    'change',
    ((web.Event _) {
      if (done) return;
      done = true;
      _readSelectedFile(input, completer);
    }).toJS,
  );

  // Fired on modern browsers when the user dismisses the picker without
  // selecting a file (Chrome 113+, Safari 17.4+).
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      if (done) return;
      done = true;
      completer.complete(null);
      input.remove();
    }).toJS,
  );

  // Fallback cancel detection: when focus returns to the window after the
  // native file dialog closes (works on browsers that don't fire 'cancel').
  JSFunction? focusFn;
  focusFn = ((web.Event _) {
    // Give the 'change' event a chance to fire first.
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (!done) {
        done = true;
        web.window.removeEventListener('focus', focusFn!);
        completer.complete(null);
        input.remove();
      } else {
        web.window.removeEventListener('focus', focusFn!);
      }
    });
  }).toJS;
  web.window.addEventListener('focus', focusFn);

  // Must be called synchronously here — before any await — so that iOS Safari
  // recognises it as originating from the user's tap gesture.
  input.click();

  return completer.future;
}

void _readSelectedFile(
  web.HTMLInputElement input,
  Completer<PickedFile?> completer,
) {
  final files = input.files;
  if (files == null || files.length == 0) {
    completer.complete(null);
    input.remove();
    return;
  }
  final file = files.item(0);
  if (file == null) {
    completer.complete(null);
    input.remove();
    return;
  }

  file.arrayBuffer().toDart.then(
    (jsBuffer) {
      final bytes = jsBuffer.toDart.asUint8List();
      final name = file.name;
      final lastDot = name.lastIndexOf('.');
      final ext =
          lastDot >= 0 && lastDot < name.length - 1
              ? name.substring(lastDot + 1).toLowerCase()
              : null;
      completer.complete(PickedFile(bytes: bytes, name: name, extension: ext));
      input.remove();
    },
    onError: (Object e) {
      completer.completeError(e);
      input.remove();
    },
  );
}
