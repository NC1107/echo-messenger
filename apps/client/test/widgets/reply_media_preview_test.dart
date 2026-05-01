import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/widgets/input/reply_preview_bar.dart';
import 'package:echo_app/src/widgets/message/media_content.dart';
import 'package:echo_app/src/widgets/message/reply_quote.dart';

import '../helpers/pump_app.dart';

ChatMessage _makeMessage({
  String content = 'Hello',
  String fromUsername = 'alice',
}) {
  return ChatMessage(
    id: 'msg-1',
    fromUserId: 'user-1',
    fromUsername: fromUsername,
    conversationId: 'conv-1',
    content: content,
    timestamp: '2026-01-15T10:00:00Z',
    isMine: false,
  );
}

void main() {
  group('replyAttachmentKind', () {
    test('plain text is none', () {
      expect(replyAttachmentKind('Hello there'), ReplyAttachmentKind.none);
    });

    test('[img:] marker is image', () {
      expect(
        replyAttachmentKind('[img:https://example.com/photo.png]'),
        ReplyAttachmentKind.image,
      );
    });

    test('[img:] marker with .gif URL is gif', () {
      expect(
        replyAttachmentKind('[img:https://example.com/anim.gif]'),
        ReplyAttachmentKind.gif,
      );
    });

    test('standalone .jpg URL is image', () {
      expect(
        replyAttachmentKind('https://cdn.example.com/pic.jpg'),
        ReplyAttachmentKind.image,
      );
    });

    test('standalone .gif URL is gif', () {
      expect(
        replyAttachmentKind('https://cdn.example.com/anim.gif'),
        ReplyAttachmentKind.gif,
      );
    });

    test('[video:] marker is video', () {
      expect(
        replyAttachmentKind('[video:https://example.com/clip.mp4]'),
        ReplyAttachmentKind.video,
      );
    });

    test('[audio:] marker is audio', () {
      expect(
        replyAttachmentKind('[audio:https://example.com/voice.ogg]'),
        ReplyAttachmentKind.audio,
      );
    });

    test('[file:] marker is file', () {
      expect(
        replyAttachmentKind('[file:https://example.com/doc.pdf]'),
        ReplyAttachmentKind.file,
      );
    });

    test('standalone .mp4 URL is video', () {
      expect(
        replyAttachmentKind('https://example.com/video.mp4'),
        ReplyAttachmentKind.video,
      );
    });

    test('api/media path without extension is image', () {
      expect(
        replyAttachmentKind('https://echo-messenger.us/api/media/abc123'),
        ReplyAttachmentKind.image,
      );
    });
  });

  group('ReplyQuote -- media attachment display', () {
    testWidgets('plain text renders a Text widget', (tester) async {
      await tester.pumpApp(
        const ReplyQuote(
          replyToUsername: 'bob',
          replyToContent: 'Hey, look at this!',
          isMine: false,
        ),
      );
      await tester.pump();

      expect(find.text('Hey, look at this!'), findsOneWidget);
      expect(find.byIcon(Icons.image_outlined), findsNothing);
    });

    testWidgets('image attachment renders thumbnail + Image widget', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpApp(
          const ReplyQuote(
            replyToUsername: 'bob',
            replyToContent: '[img:https://example.com/photo.png]',
            isMine: false,
          ),
        );
        await tester.pump();

        expect(find.byType(Image), findsOneWidget);
        expect(find.text('Image'), findsOneWidget);
      });
    });

    testWidgets('GIF attachment renders thumbnail + GIF label', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpApp(
          const ReplyQuote(
            replyToUsername: 'bob',
            replyToContent: '[img:https://example.com/anim.gif]',
            isMine: false,
          ),
        );
        await tester.pump();

        expect(find.byType(Image), findsOneWidget);
        expect(find.text('GIF'), findsOneWidget);
      });
    });

    testWidgets('video attachment renders videocam icon + Video label', (
      tester,
    ) async {
      await tester.pumpApp(
        const ReplyQuote(
          replyToUsername: 'bob',
          replyToContent: '[video:https://example.com/clip.mp4]',
          isMine: false,
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
      expect(find.text('Video'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('audio attachment renders mic icon + Voice message label', (
      tester,
    ) async {
      await tester.pumpApp(
        const ReplyQuote(
          replyToUsername: 'bob',
          replyToContent: '[audio:https://example.com/voice.ogg]',
          isMine: false,
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.mic_outlined), findsOneWidget);
      expect(find.text('Voice message'), findsOneWidget);
    });

    testWidgets('file attachment renders paperclip icon + filename', (
      tester,
    ) async {
      await tester.pumpApp(
        const ReplyQuote(
          replyToUsername: 'bob',
          replyToContent: '[file:https://example.com/report.pdf]',
          isMine: false,
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.attach_file_outlined), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
    });

    testWidgets('raw image URL does not render as text', (tester) async {
      await mockNetworkImagesFor(() async {
        const imgUrl = 'https://example.com/photo.jpg';
        await tester.pumpApp(
          const ReplyQuote(
            replyToUsername: 'alice',
            replyToContent: imgUrl,
            isMine: false,
          ),
        );
        await tester.pump();

        expect(find.text(imgUrl), findsNothing);
        expect(find.byType(Image), findsOneWidget);
      });
    });
  });

  group('ReplyPreviewBar -- media attachment display', () {
    testWidgets('plain text renders Text widget', (tester) async {
      final msg = _makeMessage(content: 'Nice photo!');
      await tester.pumpApp(
        ReplyPreviewBar(replyToMessage: msg, onDismiss: () {}),
      );
      await tester.pump();

      expect(find.text('Nice photo!'), findsOneWidget);
      expect(find.byIcon(Icons.image_outlined), findsNothing);
    });

    testWidgets('image attachment renders image icon + Image label', (
      tester,
    ) async {
      final msg = _makeMessage(content: '[img:https://example.com/photo.png]');
      await tester.pumpApp(
        ReplyPreviewBar(replyToMessage: msg, onDismiss: () {}),
      );
      await tester.pump();

      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      expect(find.text('Image'), findsOneWidget);
    });

    testWidgets('GIF attachment renders image icon + GIF label', (
      tester,
    ) async {
      final msg = _makeMessage(content: '[img:https://example.com/anim.gif]');
      await tester.pumpApp(
        ReplyPreviewBar(replyToMessage: msg, onDismiss: () {}),
      );
      await tester.pump();

      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      expect(find.text('GIF'), findsOneWidget);
    });

    testWidgets('video attachment renders videocam icon + Video label', (
      tester,
    ) async {
      final msg = _makeMessage(content: '[video:https://example.com/clip.mp4]');
      await tester.pumpApp(
        ReplyPreviewBar(replyToMessage: msg, onDismiss: () {}),
      );
      await tester.pump();

      expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
      expect(find.text('Video'), findsOneWidget);
    });

    testWidgets('audio attachment renders mic icon + Voice message label', (
      tester,
    ) async {
      final msg = _makeMessage(
        content: '[audio:https://example.com/voice.m4a]',
      );
      await tester.pumpApp(
        ReplyPreviewBar(replyToMessage: msg, onDismiss: () {}),
      );
      await tester.pump();

      expect(find.byIcon(Icons.mic_outlined), findsOneWidget);
      expect(find.text('Voice message'), findsOneWidget);
    });

    testWidgets('file attachment renders paperclip icon + filename', (
      tester,
    ) async {
      final msg = _makeMessage(
        content: '[file:https://example.com/contract.pdf]',
      );
      await tester.pumpApp(
        ReplyPreviewBar(replyToMessage: msg, onDismiss: () {}),
      );
      await tester.pump();

      expect(find.byIcon(Icons.attach_file_outlined), findsOneWidget);
      expect(find.text('contract.pdf'), findsOneWidget);
    });

    testWidgets('raw image URL does not render as text', (tester) async {
      const imgUrl = 'https://cdn.example.com/banner.webp';
      final msg = _makeMessage(content: imgUrl);
      await tester.pumpApp(
        ReplyPreviewBar(replyToMessage: msg, onDismiss: () {}),
      );
      await tester.pump();

      expect(find.text(imgUrl), findsNothing);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    });

    testWidgets('dismiss button is still present for media messages', (
      tester,
    ) async {
      var dismissed = false;
      final msg = _makeMessage(content: '[img:https://example.com/photo.png]');
      await tester.pumpApp(
        ReplyPreviewBar(replyToMessage: msg, onDismiss: () => dismissed = true),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.close));
      expect(dismissed, isTrue);
    });
  });
}
