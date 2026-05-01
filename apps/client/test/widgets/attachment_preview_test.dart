// Tests for the attachment chip rendering inside PendingAttachmentsStrip.
// "attachment_preview" in issue #637 refers to the per-chip preview shown
// above the input bar (image thumbnail, file icon, GIF label, audio icon)
// before the user sends a message.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/input/pending_attachments_strip.dart';

import '../helpers/pump_app.dart';

PendingAttachment _file(String name, {int sizeBytes = 1024}) =>
    PendingAttachment(
      bytes: Uint8List(sizeBytes),
      fileName: name,
      mimeType: 'application/octet-stream',
      ext: name.contains('.') ? name.split('.').last : '',
      sizeBytes: sizeBytes,
    );

PendingAttachment _image(String name) => PendingAttachment(
  bytes: Uint8List(512),
  fileName: name,
  mimeType: 'image/jpeg',
  ext: 'jpg',
  sizeBytes: 512,
);

PendingAttachment _audio(String name) => PendingAttachment(
  bytes: Uint8List(512),
  fileName: name,
  mimeType: 'audio/ogg',
  ext: 'ogg',
  sizeBytes: 512,
);

/// External-URL attachment (GIF from picker) — bytes is null so isExternalUrl
/// is true. This is the only path where the chip shows the "GIF" text label.
PendingAttachment _externalGif(String url) => PendingAttachment(
  bytes: null,
  fileName: 'funny.gif',
  mimeType: 'image/gif',
  ext: 'gif',
  sizeBytes: 0,
  uploadedUrl: url,
);

Widget _strip(List<PendingAttachment> items) =>
    PendingAttachmentsStrip(attachments: items, onCancel: (_) {});

void main() {
  group('Attachment chip preview rendering (#637)', () {
    testWidgets('image attachment chip renders filename', (tester) async {
      final att = _image('photo.jpg');
      await tester.pumpApp(_strip([att]));
      await tester.pump();

      // The filename is always shown regardless of thumbnail decode result.
      expect(find.text('photo.jpg'), findsOneWidget);
      // Mic (audio) icon must not appear for an image mime attachment.
      expect(find.byIcon(Icons.mic), findsNothing);
    });

    testWidgets('file attachment shows generic file icon and filename', (
      tester,
    ) async {
      final att = _file('contract.pdf', sizeBytes: 204800);
      await tester.pumpApp(_strip([att]));
      await tester.pump();

      expect(find.text('contract.pdf'), findsOneWidget);
      expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
      // Human-readable size label should appear (200.0 KB).
      expect(find.textContaining('KB'), findsOneWidget);
    });

    testWidgets('audio attachment shows mic icon', (tester) async {
      final att = _audio('voice.ogg');
      await tester.pumpApp(_strip([att]));
      await tester.pump();

      expect(find.byIcon(Icons.mic), findsOneWidget);
    });

    testWidgets('external-url GIF attachment shows "GIF" label', (
      tester,
    ) async {
      final att = _externalGif('https://media.giphy.com/funny.gif');
      await tester.pumpApp(_strip([att]));
      await tester.pump();

      expect(find.text('GIF'), findsOneWidget);
    });

    testWidgets('semantics label includes "Attached file:" prefix', (
      tester,
    ) async {
      final att = _file('slides.pptx', sizeBytes: 512);
      await tester.pumpApp(_strip([att]));
      await tester.pump();

      final semantics = tester.getSemantics(
        find.bySemanticsLabel(RegExp('Attached file: slides.pptx')),
      );
      expect(semantics.label, contains('slides.pptx'));
    });
  });
}
