import 'package:flutter_test/flutter_test.dart';

void main() {
  group('readImageFromClipboard', () {
    test(
      'Wayland: uses wl-paste when WAYLAND_DISPLAY is set',
      () async {
        // Bug: _readLinuxClipboard() always calls xclip, which is X11-only.
        // On Wayland sessions (WAYLAND_DISPLAY set or XDG_SESSION_TYPE=wayland),
        // xclip is unavailable and the paste silently returns null.
        // Expected fix: detect Wayland env vars and fall back to wl-paste.
        // Manual reproduction:
        //   1. Run app on Wayland (Fedora 43+, Ubuntu 22.04+ with Wayland).
        //   2. Copy an image to clipboard.
        //   3. Ctrl+V in chat input — observe silent failure / null return.
      },
      skip: 'requires Wayland environment for manual verification',
    );

    test(
      'iOS: readImageFromClipboard logs and returns null instead of silently falling through',
      () async {
        // Bug: readImageFromClipboard() has no Platform.isIOS branch.
        // On iOS the function falls through the if/else chain and returns null
        // without any log, giving the user no indication of why paste fails.
        // Expected fix: add Platform.isIOS branch with debugPrint log.
        // Manual reproduction:
        //   1. Run app on an iOS device or simulator.
        //   2. Copy an image to clipboard via Photos app.
        //   3. Long-press in chat input and choose Paste — observe silent failure.
      },
      skip: 'requires iOS device or simulator for manual verification',
    );
  });

  group('writeImageToClipboard', () {
    test(
      'Wayland: uses wl-copy when WAYLAND_DISPLAY is set',
      () async {
        // Bug: _writeLinuxClipboard() always calls xclip, which is X11-only.
        // On Wayland xclip fails silently.
        // Expected fix: detect Wayland env vars and use wl-copy instead.
      },
      skip: 'requires Wayland environment for manual verification',
    );
  });
}
