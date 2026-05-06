// Direct tests for [decodeAvatarImage], the decoder behind the avatar
// crop dialog (#796).
//
// The fast path (PNG/JPEG via the `image` package) is exercised here.
// The platform-decoder fallback for HEIC requires real HEIC bytes and a
// device codec, which Skia in widget tests does not provide — the
// fallback branch is covered manually on iOS hardware.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:echo_app/src/widgets/avatar_crop_dialog.dart';

void main() {
  group('decodeAvatarImage (#796)', () {
    test('decodes a PNG via the fast path', () async {
      final pngBytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 4, height: 4)),
      );
      final image = await decodeAvatarImage(pngBytes);
      expect(image, isNotNull);
      expect(image!.width, 4);
      expect(image.height, 4);
    });

    test('decodes a JPEG via the fast path', () async {
      final jpegBytes = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 4, height: 4)),
      );
      final image = await decodeAvatarImage(jpegBytes);
      expect(image, isNotNull);
      expect(image!.width, 4);
    });

    test('returns null for empty bytes', () async {
      expect(await decodeAvatarImage(Uint8List(0)), isNull);
    });

    test('returns null for non-image garbage', () async {
      final bytes = Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]);
      expect(await decodeAvatarImage(bytes), isNull);
    });

    test('HEIC-shaped bytes route through the platform fallback', () async {
      // Minimal ISOBMFF ftyp box with brand 'heic'. The platform decoder
      // can't actually decode this stub, but the fallback must fail-safe
      // (return null) instead of hanging — that's the regression #796 was
      // catching, and the matching guard is verified here.
      final fakeHeic = Uint8List.fromList([
        0x00, 0x00, 0x00, 0x18, // box size
        0x66, 0x74, 0x79, 0x70, // 'ftyp'
        0x68, 0x65, 0x69, 0x63, // brand 'heic'
        0x00, 0x00, 0x00, 0x00, // minor version
        0x68, 0x65, 0x69, 0x63, // compat brand
        0x6D, 0x69, 0x66, 0x31, // compat brand 'mif1'
      ]);
      // Bound the await so a non-resolving codec future fails the test
      // loudly instead of timing out the whole runner.
      final result = await decodeAvatarImage(fakeHeic).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('platform fallback never resolved'),
      );
      expect(result, isNull);
    });
  });
}
