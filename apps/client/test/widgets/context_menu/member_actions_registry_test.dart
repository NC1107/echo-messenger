/// Visibility tests for the member-target registry.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/context_menu/actions/member_actions_registry.dart';
import 'package:echo_app/src/widgets/context_menu/echo_context_menu.dart';

MemberTarget _t({
  bool isSelf = false,
  bool targetIsOwner = false,
  bool viewerIsAdminOrOwner = false,
  bool wireProfile = true,
  bool wireSendMessage = true,
  bool wireAddContact = false,
  bool wireRemoveContact = false,
  bool wireBlock = false,
  bool wireUnblock = false,
  bool wireKick = true,
  bool wireBan = true,
  bool wireCopyUsername = true,
  bool wireCopyUserId = true,
}) {
  return MemberTarget(
    userId: 'u1',
    username: 'alice',
    isSelf: isSelf,
    targetIsOwner: targetIsOwner,
    viewerIsAdminOrOwner: viewerIsAdminOrOwner,
    onViewProfile: wireProfile ? () {} : null,
    onSendMessage: wireSendMessage ? () {} : null,
    onAddContact: wireAddContact ? () {} : null,
    onRemoveContact: wireRemoveContact ? () {} : null,
    onBlock: wireBlock ? () {} : null,
    onUnblock: wireUnblock ? () {} : null,
    onCopyUserId: wireCopyUserId ? () {} : null,
    onCopyUsername: wireCopyUsername ? () {} : null,
    onKick: wireKick ? () {} : null,
    onBan: wireBan ? () {} : null,
  );
}

Iterable<String> _labels(ContextMenuModel m) =>
    m.sections.expand((s) => s.actions.map((a) => a.label));

void main() {
  group('member_actions_registry', () {
    test('non-self always exposes View Profile + Send Message', () {
      final labels = _labels(buildMemberMenu(_t())).toList();
      expect(labels, containsAll(<String>['View Profile', 'Send Message']));
    });

    test('targeting self hides Send Message and admin/contact sections', () {
      final labels = _labels(
        buildMemberMenu(
          _t(isSelf: true, viewerIsAdminOrOwner: true, wireBlock: true),
        ),
      ).toList();
      expect(labels, contains('View Profile'));
      expect(labels, isNot(contains('Send Message')));
      expect(labels, isNot(contains('Kick from Group')));
      expect(labels, isNot(contains('Ban from Group')));
      expect(labels, isNot(contains('Block')));
    });

    test('non-admin viewer never sees Kick / Ban', () {
      final labels = _labels(
        buildMemberMenu(_t(viewerIsAdminOrOwner: false)),
      ).toList();
      expect(labels, isNot(contains('Kick from Group')));
      expect(labels, isNot(contains('Ban from Group')));
    });

    test('admin viewer sees Kick / Ban against a regular member', () {
      final labels = _labels(
        buildMemberMenu(_t(viewerIsAdminOrOwner: true)),
      ).toList();
      expect(
        labels,
        containsAll(<String>['Kick from Group', 'Ban from Group']),
      );
    });

    test('admin viewer cannot Kick / Ban the owner', () {
      final labels = _labels(
        buildMemberMenu(_t(viewerIsAdminOrOwner: true, targetIsOwner: true)),
      ).toList();
      expect(labels, isNot(contains('Kick from Group')));
      expect(labels, isNot(contains('Ban from Group')));
    });

    test('Kick and Ban are danger-styled', () {
      final m = buildMemberMenu(_t(viewerIsAdminOrOwner: true));
      final kick = m.sections
          .expand((s) => s.actions)
          .firstWhere((a) => a.label == 'Kick from Group');
      final ban = m.sections
          .expand((s) => s.actions)
          .firstWhere((a) => a.label == 'Ban from Group');
      expect(kick.isDanger, isTrue);
      expect(ban.isDanger, isTrue);
    });

    test('Unblock surfaces when wired (without Add/Remove Contact)', () {
      final labels = _labels(buildMemberMenu(_t(wireUnblock: true))).toList();
      expect(labels, contains('Unblock'));
    });

    test('Block surfaces danger-styled when wired', () {
      final m = buildMemberMenu(_t(wireBlock: true));
      final row = m.sections
          .expand((s) => s.actions)
          .firstWhere((a) => a.label == 'Block');
      expect(row.isDanger, isTrue);
    });

    test('Copy User ID + Copy Username live in the footer', () {
      final m = buildMemberMenu(_t());
      expect(m.sections.last.actions.map((a) => a.label).toList(), [
        'Copy Username',
        'Copy User ID',
      ]);
    });
  });
}
