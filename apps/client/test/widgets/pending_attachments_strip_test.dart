import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/input/pending_attachments_strip.dart';

import '../helpers/pump_app.dart';

PendingAttachment _makeAttachment(
  String name, {
  String mime = 'application/octet-stream',
  Uint8List? bytes,
  String? uploadedUrl,
}) {
  return PendingAttachment(
    bytes: bytes ?? Uint8List(0),
    fileName: name,
    mimeType: mime,
    ext: name.split('.').last,
    sizeBytes: bytes?.length ?? 0,
    uploadedUrl: uploadedUrl,
  );
}

void main() {
  group('PendingAttachmentsStrip', () {
    testWidgets('renders nothing (SizedBox.shrink) when list is empty', (
      tester,
    ) async {
      await tester.pumpApp(
        PendingAttachmentsStrip(attachments: const [], onCancel: (_) {}),
      );
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('renders one chip per attachment with correct filename', (
      tester,
    ) async {
      final attachments = [
        _makeAttachment('photo.png', mime: 'image/png'),
        _makeAttachment('report.pdf'),
      ];
      await tester.pumpApp(
        PendingAttachmentsStrip(attachments: attachments, onCancel: (_) {}),
      );
      await tester.pump();

      expect(find.text('photo.png'), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
    });

    testWidgets('shows file icon for non-image attachments', (tester) async {
      final attachments = [_makeAttachment('doc.pdf')];
      await tester.pumpApp(
        PendingAttachmentsStrip(attachments: attachments, onCancel: (_) {}),
      );
      await tester.pump();

      expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
    });

    testWidgets(
      'tapping cancel icon fires onCancel with the right attachment',
      (tester) async {
        final att = _makeAttachment('video.mp4');
        PendingAttachment? cancelled;

        await tester.pumpApp(
          PendingAttachmentsStrip(
            attachments: [att],
            onCancel: (a) => cancelled = a,
          ),
        );
        await tester.pump();

        await tester.tap(find.byIcon(Icons.close));
        expect(cancelled, same(att));
      },
    );

    testWidgets('shows "Ready" label when attachment upload is complete', (
      tester,
    ) async {
      final att = _makeAttachment(
        'img.jpg',
        mime: 'image/jpeg',
        uploadedUrl: 'https://example.com/img.jpg',
      );
      await tester.pumpApp(
        PendingAttachmentsStrip(attachments: [att], onCancel: (_) {}),
      );
      await tester.pump();

      expect(find.text('Ready'), findsOneWidget);
    });
  });
}
