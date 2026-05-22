/// Visibility and shape tests for the message-target registry.
/// These are pure-Dart tests — no Flutter binding needed — because
/// the registry only manipulates plain data.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/context_menu/actions/message_actions_registry.dart';
import 'package:echo_app/src/widgets/context_menu/echo_context_menu.dart';

MessageTarget _baseTarget({
  bool isMine = false,
  bool isSaved = false,
  bool isEncryptedUnreadable = false,
  String? mediaUrl,
  bool isImageMedia = false,
  bool wireDelete = true,
  bool wirePin = true,
  bool wireSave = true,
  bool wireReact = true,
  bool wireRetry = false,
  bool wireCopyId = true,
}) {
  return MessageTarget(
    message: const _StubMessage(),
    isMine: isMine,
    isSaved: isSaved,
    isEncryptedUnreadable: isEncryptedUnreadable,
    mediaUrl: mediaUrl,
    isImageMedia: isImageMedia,
    onReply: () {},
    onForward: () {},
    onRetry: wireRetry ? () {} : null,
    onCopyText: () {},
    onPin: wirePin ? () {} : null,
    onUnpin: null,
    onSave: wireSave && !isSaved ? () {} : null,
    onUnsave: wireSave && isSaved ? () {} : null,
    onEdit: isMine ? () {} : null,
    onViewGallery: isImageMedia ? () {} : null,
    onDelete: wireDelete ? () {} : null,
    onCopyId: wireCopyId ? () {} : null,
    onPickReaction: wireReact ? (_) {} : null,
    onOpenFullPicker: wireReact ? () {} : null,
  );
}

Iterable<String> _allLabels(ContextMenuModel m) sync* {
  for (final s in m.sections) {
    for (final a in s.actions) {
      yield a.label;
    }
  }
}

void main() {
  group('message_actions_registry', () {
    test('encrypted-unreadable message hides the inline reactions row', () {
      final m = buildMessageMenu(_baseTarget(isEncryptedUnreadable: true));
      expect(m.header, isNull);
    });

    test('normal message shows the inline reactions row', () {
      final m = buildMessageMenu(_baseTarget());
      expect(m.header, isA<InlineReactionsHeader>());
    });

    test('reactions row is hidden when callbacks are null even if not '
        'encrypted', () {
      final m = buildMessageMenu(_baseTarget(wireReact: false));
      expect(m.header, isNull);
    });

    test('own messages get the danger-styled Delete row', () {
      final m = buildMessageMenu(_baseTarget(isMine: true));
      final danger = m.sections.firstWhere(
        (s) => s.actions.any((a) => a.label == 'Delete Message'),
      );
      expect(danger.actions.first.isDanger, isTrue);
    });

    test("other people's messages show 'Delete for Me', not danger-styled", () {
      final m = buildMessageMenu(_baseTarget(isMine: false));
      final row = m.sections
          .expand((s) => s.actions)
          .firstWhere((a) => a.label == 'Delete for Me');
      expect(row.isDanger, isFalse);
    });

    test('saved messages render Unsave (not Save)', () {
      final m = buildMessageMenu(_baseTarget(isSaved: true));
      final labels = _allLabels(m).toList();
      expect(labels, contains('Unsave'));
      expect(labels, isNot(contains('Save')));
    });

    test('media images expose "View in Gallery"', () {
      final m = buildMessageMenu(
        _baseTarget(mediaUrl: 'https://x/y.png', isImageMedia: true),
      );
      expect(_allLabels(m), contains('View in Gallery'));
    });

    test('text-only message hides "View in Gallery"', () {
      final m = buildMessageMenu(_baseTarget());
      expect(_allLabels(m), isNot(contains('View in Gallery')));
    });

    test('failed sends show Retry first', () {
      final m = buildMessageMenu(_baseTarget(wireRetry: true));
      expect(m.sections.first.actions.first.label, 'Retry');
    });

    test('Copy Message ID lives in its own footer section', () {
      final m = buildMessageMenu(_baseTarget());
      expect(m.sections.last.actions.map((a) => a.label).toList(), [
        'Copy Message ID',
      ]);
    });

    test('Copy Message ID is absent when onCopyId is null', () {
      final m = buildMessageMenu(_baseTarget(wireCopyId: false));
      expect(_allLabels(m), isNot(contains('Copy Message ID')));
    });

    test('right-click menu exposes a labeled "Add reaction" row', () {
      final m = buildMessageMenu(_baseTarget());
      expect(_allLabels(m), contains('Add reaction'));
    });

    test('"Add reaction" is hidden on encrypted-unreadable messages', () {
      final m = buildMessageMenu(_baseTarget(isEncryptedUnreadable: true));
      expect(_allLabels(m), isNot(contains('Add reaction')));
    });

    test('"Add reaction" is hidden when reactions are not wired', () {
      final m = buildMessageMenu(_baseTarget(wireReact: false));
      expect(_allLabels(m), isNot(contains('Add reaction')));
    });

    test('media messages show "Copy link" instead of "Copy text"', () {
      final m = buildMessageMenu(
        _baseTarget(mediaUrl: 'https://x/y.bin', isImageMedia: false),
      );
      final labels = _allLabels(m).toList();
      expect(labels, contains('Copy link'));
      expect(labels, isNot(contains('Copy text')));
    });
  });
}

class _StubMessage {
  const _StubMessage();
}
