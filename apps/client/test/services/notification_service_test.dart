import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/services/notification_service.dart';

// ---------------------------------------------------------------------------
// Minimal stub implementation for in-process unit testing.
//
// Flutter's conditional import (`notification_service_stub.dart` vs
// `notification_service_web.dart`) pulls in platform code that depends on
// `flutter_local_notifications` on desktop/mobile or the Web Notifications
// API on web — neither of which is available in the test environment.
//
// We therefore define a lightweight stub that implements the full
// [NotificationService] interface and exercise the interface contract.
// ---------------------------------------------------------------------------

class _StubNotificationService implements NotificationService {
  final List<Map<String, Object?>> shown = [];
  final List<String> cancelled = [];
  bool allCancelled = false;
  bool appFocused = true;
  int lastBadgeCount = 0;
  bool preferencesRefreshed = false;

  final _tapController = StreamController<String>.broadcast();

  @override
  Future<void> requestPermission() async {}

  @override
  Future<bool> promptPermission() async => true;

  @override
  void showMessageNotification({
    required String senderUsername,
    required String body,
    String? conversationId,
    String? conversationName,
    bool isGroup = false,
    bool isMuted = false,
    bool forceShow = false,
  }) {
    if (isMuted) return;
    if (!forceShow && appFocused) return;
    shown.add({
      'senderUsername': senderUsername,
      'body': body,
      'conversationId': conversationId,
      'isGroup': isGroup,
    });
  }

  @override
  void cancelConversationNotifications(String conversationId) {
    cancelled.add(conversationId);
  }

  @override
  void cancelAll() {
    allCancelled = true;
  }

  @override
  void updateTabBadge(int totalUnread) {
    lastBadgeCount = totalUnread;
  }

  @override
  void setAppFocused(bool focused) {
    appFocused = focused;
  }

  @override
  void refreshPreferences() {
    preferencesRefreshed = true;
  }

  @override
  Stream<String> get onNotificationTap => _tapController.stream;

  void simulateTap(String conversationId) {
    _tapController.add(conversationId);
  }

  Future<void> dispose() => _tapController.close();
}

void main() {
  late _StubNotificationService svc;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    svc = _StubNotificationService();
  });

  tearDown(() async {
    await svc.dispose();
  });

  // ---------------------------------------------------------------------------
  // requestPermission / promptPermission
  // ---------------------------------------------------------------------------

  group('NotificationService.requestPermission', () {
    test('completes without error', () async {
      await expectLater(svc.requestPermission(), completes);
    });
  });

  group('NotificationService.promptPermission', () {
    test('returns true by default', () async {
      expect(await svc.promptPermission(), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // showMessageNotification
  // ---------------------------------------------------------------------------

  group('NotificationService.showMessageNotification', () {
    test('shows notification when app is backgrounded', () {
      svc.setAppFocused(false);
      svc.showMessageNotification(
        senderUsername: 'alice',
        body: 'Hey!',
        conversationId: 'conv-1',
      );
      expect(svc.shown, hasLength(1));
      expect(svc.shown.first['senderUsername'], 'alice');
    });

    test('suppresses notification when app is focused', () {
      svc.setAppFocused(true);
      svc.showMessageNotification(
        senderUsername: 'alice',
        body: 'Hey!',
        conversationId: 'conv-1',
      );
      expect(svc.shown, isEmpty);
    });

    test('forceShow bypasses focus suppression', () {
      svc.setAppFocused(true);
      svc.showMessageNotification(
        senderUsername: 'alice',
        body: 'Test notification!',
        conversationId: 'conv-1',
        forceShow: true,
      );
      expect(svc.shown, hasLength(1));
    });

    test('isMuted suppresses notification even with forceShow', () {
      svc.setAppFocused(false);
      svc.showMessageNotification(
        senderUsername: 'alice',
        body: 'Muted message',
        conversationId: 'conv-1',
        isMuted: true,
        forceShow: true,
      );
      expect(svc.shown, isEmpty);
    });

    test('isMuted takes priority over forceShow (ordering verified)', () {
      svc.setAppFocused(true);

      // forceShow=true alone is sufficient to bypass focus suppression
      svc.showMessageNotification(
        senderUsername: 'first',
        body: 'force-shown',
        forceShow: true,
      );
      expect(svc.shown, hasLength(1));

      // isMuted=true still suppresses even when forceShow=true
      svc.showMessageNotification(
        senderUsername: 'second',
        body: 'muted overrides force',
        isMuted: true,
        forceShow: true,
      );
      // Count stays at 1 — second notification was suppressed by isMuted
      expect(svc.shown, hasLength(1));
    });

    test('notification payload includes conversationId', () {
      svc.setAppFocused(false);
      svc.showMessageNotification(
        senderUsername: 'bob',
        body: 'Hello',
        conversationId: 'conv-xyz',
      );
      expect(svc.shown.first['conversationId'], 'conv-xyz');
    });

    test('group flag is forwarded in notification payload', () {
      svc.setAppFocused(false);
      svc.showMessageNotification(
        senderUsername: 'Group',
        body: 'Group message',
        conversationId: 'group-1',
        isGroup: true,
      );
      expect(svc.shown.first['isGroup'], isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // cancelConversationNotifications / cancelAll
  // ---------------------------------------------------------------------------

  group('NotificationService.cancelConversationNotifications', () {
    test('records the cancelled conversation id', () {
      svc.cancelConversationNotifications('conv-1');
      expect(svc.cancelled, contains('conv-1'));
    });

    test('can cancel multiple conversations', () {
      svc.cancelConversationNotifications('conv-a');
      svc.cancelConversationNotifications('conv-b');
      expect(svc.cancelled, containsAll(['conv-a', 'conv-b']));
    });
  });

  group('NotificationService.cancelAll', () {
    test('sets allCancelled flag', () {
      svc.cancelAll();
      expect(svc.allCancelled, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // updateTabBadge
  // ---------------------------------------------------------------------------

  group('NotificationService.updateTabBadge', () {
    test('stores the badge count', () {
      svc.updateTabBadge(5);
      expect(svc.lastBadgeCount, 5);
    });

    test('zero clears the badge', () {
      svc.updateTabBadge(3);
      svc.updateTabBadge(0);
      expect(svc.lastBadgeCount, 0);
    });
  });

  // ---------------------------------------------------------------------------
  // setAppFocused / refreshPreferences
  // ---------------------------------------------------------------------------

  group('NotificationService.setAppFocused', () {
    test('toggling focus affects notification suppression', () {
      svc.setAppFocused(false);
      svc.showMessageNotification(senderUsername: 'a', body: 'x');
      expect(svc.shown, hasLength(1));

      svc.setAppFocused(true);
      svc.showMessageNotification(senderUsername: 'b', body: 'y');
      // Still 1 — second notification suppressed by focus
      expect(svc.shown, hasLength(1));
    });
  });

  group('NotificationService.refreshPreferences', () {
    test('marks preferences as refreshed', () {
      svc.refreshPreferences();
      expect(svc.preferencesRefreshed, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // onNotificationTap stream
  // ---------------------------------------------------------------------------

  group('NotificationService.onNotificationTap', () {
    test('emits conversation id when notification is tapped', () async {
      final received = <String>[];
      final sub = svc.onNotificationTap.listen(received.add);

      svc.simulateTap('conv-opened');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(received, contains('conv-opened'));
      await sub.cancel();
    });

    test('stream is a broadcast stream (multiple listeners allowed)', () {
      final sub1 = svc.onNotificationTap.listen((_) {});
      final sub2 = svc.onNotificationTap.listen((_) {});
      // Both listeners registered without error
      sub1.cancel();
      sub2.cancel();
    });
  });
}
