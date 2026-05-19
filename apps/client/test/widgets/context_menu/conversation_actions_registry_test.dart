/// Visibility tests for the conversation-target registry.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/context_menu/actions/conversation_actions_registry.dart';
import 'package:echo_app/src/widgets/context_menu/echo_context_menu.dart';

ConversationTarget _t({
  bool isGroup = true,
  bool isPinned = false,
  bool isMuted = false,
  bool hasUnread = false,
  bool isAdminOrOwner = false,
  bool wireLeave = false,
  bool wireDelete = false,
  bool wireInfo = true,
  bool wireInvite = false,
  bool wireSafetyNumber = false,
  bool wireEncryptionActivity = false,
  bool wireCopyId = true,
  bool wireMarkAsRead = true,
  bool wireMarkAsUnread = false,
  bool wireTogglePin = true,
  bool wireToggleMute = true,
}) {
  return ConversationTarget(
    conversationId: 'conv-1',
    isGroup: isGroup,
    isPinned: isPinned,
    isMuted: isMuted,
    hasUnread: hasUnread,
    isAdminOrOwner: isAdminOrOwner,
    onMarkAsRead: wireMarkAsRead ? () {} : null,
    onMarkAsUnread: wireMarkAsUnread ? () {} : null,
    onToggleMute: wireToggleMute ? () {} : null,
    onTogglePin: wireTogglePin ? () {} : null,
    onOpenInfo: wireInfo ? () {} : null,
    onInvitePeople: wireInvite ? () {} : null,
    onOpenEncryptionActivity: wireEncryptionActivity ? () {} : null,
    onViewSafetyNumber: wireSafetyNumber ? () {} : null,
    onCopyId: wireCopyId ? () {} : null,
    onLeave: wireLeave ? () {} : null,
    onDelete: wireDelete ? () {} : null,
  );
}

Iterable<String> _labels(ContextMenuModel m) =>
    m.sections.expand((s) => s.actions.map((a) => a.label));

void main() {
  group('conversation_actions_registry', () {
    test('Mark As Read appears only when there is unread', () {
      expect(
        _labels(buildConversationMenu(_t(hasUnread: true))),
        contains('Mark As Read'),
      );
      expect(
        _labels(buildConversationMenu(_t(hasUnread: false))),
        isNot(contains('Mark As Read')),
      );
    });

    test('Mute label flips with isMuted', () {
      expect(
        _labels(buildConversationMenu(_t(isMuted: false))),
        contains('Mute'),
      );
      expect(
        _labels(buildConversationMenu(_t(isMuted: true))),
        contains('Unmute'),
      );
    });

    test('Pin label flips with isPinned', () {
      expect(
        _labels(buildConversationMenu(_t(isPinned: false))),
        contains('Pin to Top'),
      );
      expect(
        _labels(buildConversationMenu(_t(isPinned: true))),
        contains('Unpin'),
      );
    });

    test('DM hides Group Info but exposes Safety Number', () {
      final m = buildConversationMenu(
        _t(isGroup: false, wireSafetyNumber: true),
      );
      final labels = _labels(m).toList();
      expect(labels, isNot(contains('Group Info')));
      expect(labels, contains('View Safety Number'));
    });

    test('Group exposes Group Info, hides Safety Number', () {
      final m = buildConversationMenu(_t(isGroup: true));
      final labels = _labels(m).toList();
      expect(labels, contains('Group Info'));
      expect(labels, isNot(contains('View Safety Number')));
    });

    test('Encryption Activity is admin/owner only', () {
      final adminLabels = _labels(
        buildConversationMenu(
          _t(isAdminOrOwner: true, wireEncryptionActivity: true),
        ),
      ).toList();
      expect(adminLabels, contains('Encryption Activity'));

      final memberLabels = _labels(
        buildConversationMenu(
          _t(isAdminOrOwner: false, wireEncryptionActivity: true),
        ),
      ).toList();
      expect(memberLabels, isNot(contains('Encryption Activity')));
    });

    test('Leave Group renders danger-styled when wired', () {
      final m = buildConversationMenu(_t(wireLeave: true));
      final row = m.sections
          .expand((s) => s.actions)
          .firstWhere((a) => a.label == 'Leave Group');
      expect(row.isDanger, isTrue);
    });

    test('Delete label flips between Group and DM', () {
      expect(
        _labels(buildConversationMenu(_t(isGroup: true, wireDelete: true))),
        contains('Delete Group'),
      );
      expect(
        _labels(buildConversationMenu(_t(isGroup: false, wireDelete: true))),
        contains('Delete Conversation'),
      );
    });

    test('Copy Conversation ID lives in the footer', () {
      final m = buildConversationMenu(_t());
      expect(m.sections.last.actions.map((a) => a.label).toList(), [
        'Copy Conversation ID',
      ]);
    });
  });
}
