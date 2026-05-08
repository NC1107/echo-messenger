import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/widgets/input/mention_controller.dart';

void main() {
  group('MentionComposerController', () {
    late MentionComposerController controller;
    late int notifyCount;

    setUp(() {
      controller = MentionComposerController();
      notifyCount = 0;
      controller.addListener(() => notifyCount++);
    });

    tearDown(() => controller.dispose());

    test('starts hidden with empty query', () {
      expect(controller.showPicker, isFalse);
      expect(controller.query, isEmpty);
    });

    test('detect activates picker on @ in group', () {
      controller.detect(text: '@al', cursorPosition: 3, isGroup: true);
      expect(controller.showPicker, isTrue);
      expect(controller.query, 'al');
      expect(notifyCount, 1);
    });

    test('detect is a no-op when state is unchanged', () {
      controller.detect(text: '@al', cursorPosition: 3, isGroup: true);
      controller.detect(text: '@al', cursorPosition: 3, isGroup: true);
      expect(notifyCount, 1, reason: 'second identical call should not notify');
    });

    test('detect dismisses picker in 1:1 DM regardless of @', () {
      controller.detect(text: '@al', cursorPosition: 3, isGroup: false);
      expect(controller.showPicker, isFalse);
      expect(controller.query, isEmpty);
      expect(notifyCount, 0, reason: 'starts hidden, no transition fired');
    });

    test('detect closes picker when query terminator typed', () {
      controller
        ..detect(text: '@al', cursorPosition: 3, isGroup: true)
        ..detect(text: '@al ', cursorPosition: 4, isGroup: true);
      expect(controller.showPicker, isFalse);
      expect(controller.query, isEmpty);
      expect(notifyCount, 2, reason: 'open then close');
    });

    test('dismiss closes picker and clears query', () {
      controller.detect(text: '@al', cursorPosition: 3, isGroup: true);
      controller.dismiss();
      expect(controller.showPicker, isFalse);
      expect(controller.query, isEmpty);
    });

    test('dismiss while already hidden does not notify', () {
      controller.dismiss();
      expect(notifyCount, 0);
    });

    test('filterMembers removes the local user', () {
      const me = ConversationMember(userId: 'me', username: 'testuser');
      const other = ConversationMember(userId: 'other', username: 'alice');
      final filtered = MentionComposerController.filterMembers([
        me,
        other,
      ], 'me');
      expect(filtered, hasLength(1));
      expect(filtered.first.userId, 'other');
    });
  });
}
