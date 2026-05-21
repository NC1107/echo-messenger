import 'dart:async';

import 'package:echo_app/src/providers/admin_realtime_provider.dart';
import 'package:echo_app/src/providers/admin_stats_provider.dart';
import 'package:echo_app/src/screens/admin/admin_dashboard_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget tests for the admin dashboard (#682, #681 Phase 1). We swap in
/// fake notifiers so the screen renders deterministically without hitting
/// the network.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required AdminDashboardNotifier Function() override,
    AdminRealtimeNotifier Function()? realtimeOverride,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminDashboardProvider.overrideWith(override),
          adminRealtimeProvider.overrideWith(
            realtimeOverride ?? _RealtimeStubNotifier.new,
          ),
        ],
        child: const MaterialApp(home: AdminDashboardScreen()),
      ),
    );
  }

  testWidgets('renders the loading state', (tester) async {
    await pump(tester, override: _LoadingNotifier.new);
    // No settle — the loading state is intentionally indefinite.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Admin Dashboard'), findsOneWidget);
  });

  testWidgets('renders the error state with a retry affordance', (
    tester,
  ) async {
    await pump(tester, override: _ErrorNotifier.new);
    await tester.pumpAndSettle();
    expect(find.text('Could not load admin data'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
  });

  testWidgets('renders stat cards and a feedback row on success', (
    tester,
  ) async {
    await pump(tester, override: _SuccessNotifier.new);
    await tester.pumpAndSettle();

    // Stats labels.
    expect(find.text('Users (total)'), findsOneWidget);
    expect(find.text('Messages 24h'), findsOneWidget);
    expect(find.text('Active 24h'), findsOneWidget);

    // Mocked feedback row is visible.
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('Server is on fire'), findsOneWidget);
    expect(find.text('Recent feedback'), findsOneWidget);
  });

  testWidgets('renders an empty-state when feedback list is empty', (
    tester,
  ) async {
    await pump(tester, override: _EmptyFeedbackNotifier.new);
    await tester.pumpAndSettle();
    expect(find.text('No open feedback.'), findsOneWidget);
  });

  // ------------------------------------------------------------------
  // #681 Phase 1: realtime section
  // ------------------------------------------------------------------

  testWidgets('renders the four realtime cards on success', (tester) async {
    await pump(
      tester,
      override: _SuccessNotifier.new,
      realtimeOverride: _RealtimeStubNotifier.new,
    );
    await tester.pumpAndSettle();

    // All four card labels should be present.
    expect(find.text('Connected sessions'), findsOneWidget);
    expect(find.text('Messages / sec'), findsOneWidget);
    expect(find.text('Voice rooms'), findsOneWidget);
    expect(find.text('DB pool'), findsOneWidget);

    // Stat values from the stub.
    expect(
      find.byKey(const Key('admin-realtime-card-sessions')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin-realtime-card-mps')), findsOneWidget);
    expect(find.byKey(const Key('admin-realtime-card-voice')), findsOneWidget);
    expect(find.byKey(const Key('admin-realtime-card-db')), findsOneWidget);
  });

  testWidgets('renders a friendly message when the server returns 403', (
    tester,
  ) async {
    await pump(
      tester,
      override: _SuccessNotifier.new,
      realtimeOverride: _ForbiddenRealtimeNotifier.new,
    );
    await tester.pumpAndSettle();

    expect(find.text("You're not an admin on this server."), findsOneWidget);
    expect(find.byKey(const Key('admin-realtime-error')), findsOneWidget);
  });

  testWidgets('renders the reauth-required surface for 401 reauth', (
    tester,
  ) async {
    await pump(
      tester,
      override: _SuccessNotifier.new,
      realtimeOverride: _ReauthRealtimeNotifier.new,
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Re-enter your password to view realtime stats.'),
      findsOneWidget,
    );
  });
}

// ---------------------------------------------------------------------------
// Fake notifier variants. Each one short-circuits the build() to a fixed
// AsyncValue so the widget tree is fully deterministic.
// ---------------------------------------------------------------------------

class _LoadingNotifier extends AdminDashboardNotifier {
  @override
  Future<AdminDashboardData> build() {
    // A never-completing future keeps state stuck in AsyncLoading for the
    // duration of the test, without us having to manually emit a state
    // value through the Notifier API.
    return Completer<AdminDashboardData>().future;
  }
}

class _ErrorNotifier extends AdminDashboardNotifier {
  @override
  Future<AdminDashboardData> build() {
    return Future.error(Exception('HTTP 403'));
  }
}

class _SuccessNotifier extends AdminDashboardNotifier {
  @override
  Future<AdminDashboardData> build() async {
    return AdminDashboardData(
      stats: const AdminStats(
        usersTotal: 42,
        usersActive24h: 7,
        messages24h: 318,
        groupsTotal: 5,
        onlineDevices: 11,
        feedbackOpen: 2,
        feedbackLast24h: 1,
      ),
      feedback: [
        FeedbackItem(
          id: 'fb-1',
          userId: 'u-1',
          username: 'alice',
          title: 'Server is on fire',
          body: 'The voice chat dropped twice last night.',
          publicOk: true,
          status: 'open',
          createdAt: DateTime.utc(2026, 5, 14, 12, 0, 0),
        ),
      ],
    );
  }
}

class _EmptyFeedbackNotifier extends AdminDashboardNotifier {
  @override
  Future<AdminDashboardData> build() async {
    return const AdminDashboardData(
      stats: AdminStats(
        usersTotal: 0,
        usersActive24h: 0,
        messages24h: 0,
        groupsTotal: 0,
        onlineDevices: 0,
        feedbackOpen: 0,
        feedbackLast24h: 0,
      ),
      feedback: [],
    );
  }
}

/// Default realtime stub: always-success with deterministic numbers.
class _RealtimeStubNotifier extends AdminRealtimeNotifier {
  @override
  Future<AdminRealtimeStats> build() async {
    return const AdminRealtimeStats(
      connectedSessions: 12,
      connectedSessionsByPlatform: PlatformBreakdown(
        web: 0,
        mobile: 0,
        desktop: 0,
        unknown: 12,
      ),
      messagesPerSec: 1.25,
      activeVoiceRooms: 2,
      dbPoolInFlight: 3,
      dbPoolMax: 32,
    );
  }
}

class _ForbiddenRealtimeNotifier extends AdminRealtimeNotifier {
  @override
  Future<AdminRealtimeStats> build() {
    return Future.error(const AdminForbidden());
  }
}

class _ReauthRealtimeNotifier extends AdminRealtimeNotifier {
  @override
  Future<AdminRealtimeStats> build() {
    return Future.error(const AdminReauthRequired());
  }
}
