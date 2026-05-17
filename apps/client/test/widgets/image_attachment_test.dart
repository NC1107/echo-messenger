// Widget tests for ImageAttachment — aspect-ratio reservation and
// session-scoped dimension cache.
//
// These tests verify that:
//   1. When width + height are provided, the rendered widget tree contains an
//      AspectRatio with the correct ratio before any image bytes arrive.
//   2. When dimensions are absent (legacy messages), no AspectRatio is added.
//   3. cacheImageDimensions() pre-populates the session cache so a subsequent
//      ImageAttachment with the same URL uses the cached ratio automatically.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/message/image_attachment.dart';

import '../helpers/pump_app.dart';

void main() {
  // Wipe the session cache before each test for isolation.
  setUp(() => imageDimensionCache.clear());

  group('ImageAttachment aspect-ratio reservation', () {
    testWidgets('wraps in AspectRatio when width and height are provided', (
      tester,
    ) async {
      await tester.pumpApp(
        const ImageAttachment(
          imageUrl: 'https://example.com/img.png',
          headers: {},
          imageWidth: 400,
          imageHeight: 200,
        ),
      );
      // AspectRatio widget should be in the tree.
      expect(find.byType(AspectRatio), findsOneWidget);

      // The ratio should be width / height = 400 / 200 = 2.0.
      final aspectRatio = tester.widget<AspectRatio>(find.byType(AspectRatio));
      expect(aspectRatio.aspectRatio, closeTo(2.0, 0.001));
    });

    testWidgets('does not add AspectRatio when dimensions are absent', (
      tester,
    ) async {
      await tester.pumpApp(
        const ImageAttachment(
          imageUrl: 'https://example.com/img.png',
          headers: {},
          // No imageWidth / imageHeight — legacy message.
        ),
      );
      expect(find.byType(AspectRatio), findsNothing);
    });

    testWidgets('uses session cache when no explicit dimensions are passed', (
      tester,
    ) async {
      const url = '/api/media/abc-123';
      // Pre-populate the session cache as the upload path would.
      cacheImageDimensions(url, 300, 100);

      await tester.pumpApp(const ImageAttachment(imageUrl: url, headers: {}));
      // The cache provides 300x100 → ratio 3.0.
      expect(find.byType(AspectRatio), findsOneWidget);
      final aspectRatio = tester.widget<AspectRatio>(find.byType(AspectRatio));
      expect(aspectRatio.aspectRatio, closeTo(3.0, 0.001));
    });

    testWidgets('explicit dimensions take priority over the session cache', (
      tester,
    ) async {
      const url = '/api/media/abc-456';
      // Cache stores a different size (e.g. from a previous render).
      cacheImageDimensions(url, 100, 100); // ratio 1.0

      await tester.pumpApp(
        const ImageAttachment(
          imageUrl: url,
          headers: {},
          imageWidth: 800,
          imageHeight: 400, // explicit ratio 2.0 should win
        ),
      );
      final aspectRatio = tester.widget<AspectRatio>(find.byType(AspectRatio));
      expect(aspectRatio.aspectRatio, closeTo(2.0, 0.001));
    });
  });
}
