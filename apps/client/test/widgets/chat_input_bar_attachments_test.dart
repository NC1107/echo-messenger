import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/widgets/chat_input_bar.dart';
import 'package:echo_app/src/widgets/input/pending_attachments_strip.dart';

import '../helpers/pump_app.dart';
import 'chat_input_bar_test.dart' show chatOverride, voiceSettingsOverride;
import '../helpers/mock_providers.dart';

/// A [ValueNotifier] that records the dispose call so the test can assert
/// every staged attachment's notifier was actually released.
class _TrackedAttachment extends PendingAttachment {
  bool disposed = false;

  _TrackedAttachment(String name)
    : super(
        bytes: Uint8List(0),
        fileName: name,
        mimeType: 'application/octet-stream',
        ext: 'bin',
        sizeBytes: 0,
      );

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

const _convA = Conversation(
  id: 'conv-a',
  isGroup: false,
  isEncrypted: true,
  members: [
    ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ConversationMember(userId: 'user-alice', username: 'alice'),
  ],
);

void main() {
  group('ChatInputBar attachment disposal (#623)', () {
    test('PendingAttachment.dispose releases its ValueNotifier', () {
      final att = _TrackedAttachment('a.png');
      // ValueNotifier must accept addListener before dispose.
      att.progress.addListener(() {});
      att.dispose();
      expect(att.disposed, isTrue);
      // Adding a listener after dispose must throw — confirms the notifier
      // was actually released, not just flagged.
      expect(() => att.progress.addListener(() {}), throwsFlutterError);
    });

    test('disposing many attachments releases every notifier', () {
      final attachments = List<_TrackedAttachment>.generate(
        5,
        (i) => _TrackedAttachment('a$i.png'),
      );
      for (final a in attachments) {
        a.dispose();
      }
      expect(attachments.every((a) => a.disposed), isTrue);
      // Each notifier is now disposed — addListener must throw.
      for (final a in attachments) {
        expect(() => a.progress.addListener(() {}), throwsFlutterError);
      }
    });

    testWidgets('disposing the input bar does not throw', (tester) async {
      await tester.pumpApp(
        ChatInputBar(conversation: _convA, onMessageSent: () {}),
        overrides: [
          ...standardOverrides(),
          chatOverride(),
          voiceSettingsOverride(),
        ],
      );
      await tester.pump();
      // Replace with an empty widget to trigger State.dispose on the bar.
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  });
}
