import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/image_gallery_viewer.dart';

Future<void> _pumpViewer(
  WidgetTester tester,
  List<String> urls, {
  int initialIndex = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: Scaffold(
        body: ImageGalleryViewer(imageUrls: urls, initialIndex: initialIndex),
      ),
    ),
  );
  // Let the fade-in animation start; full settle would hang on PageView.
  await tester.pump();
}

void main() {
  group('ImageGalleryViewer', () {
    testWidgets('renders the close button when shown', (tester) async {
      // Single-image gallery: counter chip is hidden, close button still
      // renders.
      await _pumpViewer(tester, const ['https://example.com/a.jpg']);
      expect(find.byIcon(Icons.close), findsOneWidget);
      // The counter "1 of N" only appears when there is more than one image.
      expect(find.textContaining(' of '), findsNothing);
    });

    testWidgets('shows "N of M" counter for multi-image galleries', (
      tester,
    ) async {
      await _pumpViewer(tester, const [
        'https://example.com/a.jpg',
        'https://example.com/b.jpg',
        'https://example.com/c.jpg',
      ]);
      expect(find.text('1 of 3'), findsOneWidget);
    });

    testWidgets('honours initialIndex for the starting page label', (
      tester,
    ) async {
      await _pumpViewer(tester, const [
        'https://example.com/a.jpg',
        'https://example.com/b.jpg',
        'https://example.com/c.jpg',
      ], initialIndex: 2);
      expect(find.text('3 of 3'), findsOneWidget);
    });

    testWidgets('shows prev/next nav buttons and a download button', (
      tester,
    ) async {
      await _pumpViewer(tester, const [
        'https://example.com/a.jpg',
        'https://example.com/b.jpg',
      ]);
      expect(find.byIcon(Icons.chevron_left), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    });
  });
}
