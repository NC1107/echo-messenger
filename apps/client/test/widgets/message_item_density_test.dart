import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/providers/theme_provider.dart' show UIDensity;
import 'package:echo_app/src/widgets/message/rich_text_content.dart';
import 'package:echo_app/src/widgets/message_item.dart';

import '../helpers/pump_app.dart';

ChatMessage _msg() => const ChatMessage(
  id: 'msg-1',
  fromUserId: 'peer',
  fromUsername: 'alice',
  conversationId: 'conv-1',
  content: 'Hello world',
  timestamp: '2026-05-08T10:30:00Z',
  isMine: false,
  status: MessageStatus.sent,
);

Future<RichTextContent> _pumpAndFindContent(
  WidgetTester tester,
  UIDensity density,
) async {
  await mockNetworkImagesFor(() async {
    await tester.pumpApp(
      MessageItem(
        message: _msg(),
        showHeader: true,
        isLastInGroup: true,
        myUserId: 'me',
        density: density,
      ),
    );
    await tester.pump();
  });
  // The bubble may host more than one RichTextContent (caption +
  // body) but the test message has no caption, so just one is
  // present.
  return tester.widget<RichTextContent>(find.byType(RichTextContent));
}

void main() {
  group('MessageItem density', () {
    testWidgets('cozy passes UIDensity.cozy down to RichTextContent', (
      tester,
    ) async {
      final content = await _pumpAndFindContent(tester, UIDensity.cozy);
      expect(content.density, UIDensity.cozy);
    });

    testWidgets('normal passes UIDensity.normal down to RichTextContent', (
      tester,
    ) async {
      final content = await _pumpAndFindContent(tester, UIDensity.normal);
      expect(content.density, UIDensity.normal);
    });

    testWidgets('compact passes UIDensity.compact down to RichTextContent', (
      tester,
    ) async {
      final content = await _pumpAndFindContent(tester, UIDensity.compact);
      expect(content.density, UIDensity.compact);
    });
  });
}
