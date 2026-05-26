import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../widgets/context_menu/context_menu_testbed.dart';
import '../screens/admin/admin_dashboard_screen.dart';
import '../screens/contacts_screen.dart';
import '../screens/create_group_screen.dart';
import '../screens/discover_groups_screen.dart';
import '../screens/forgot_password_screen.dart';
import '../screens/group_info_screen.dart';
import '../screens/home_screen.dart';
import '../screens/join_group_screen.dart';
import '../screens/token_join_screen.dart';
import '../screens/login_screen.dart';
import '../screens/onboarding_wizard.dart';
import '../screens/register_screen.dart';
import '../screens/reset_password_screen.dart';
import '../screens/safety_number_screen.dart';
import '../screens/saved_messages_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/splash_screen.dart';
import '../screens/username_invite_screen.dart';
import '../screens/user_profile_screen.dart';

const _routeHome = '/home';
const _routeLogin = '/login';
const _routeSplash = '/splash';

// ---------------------------------------------------------------------------
// Pending Deep Link State Management
// ---------------------------------------------------------------------------

/// Manages pending deep links requested before authentication.
/// Deep links are stored when the user attempts an unauthenticated navigation,
/// then resolved after successful login/auto-login for reactive routing.
class _PendingDeepLinkNotifier extends StateNotifier<String?> {
  _PendingDeepLinkNotifier() : super(null);

  void set(String? link) => state = link;

  String? takeAndClear() {
    final link = state;
    state = null;
    return link;
  }
}

final _pendingDeepLinkProvider =
    StateNotifierProvider<_PendingDeepLinkNotifier, String?>(
      (ref) => _PendingDeepLinkNotifier(),
    );

/// Exported provider for accessing and mutating pending deep-link state.
final pendingDeepLinkProvider = _pendingDeepLinkProvider;

/// Shared fade transition used by all routes.
CustomTransitionPage<void> _fadePage({
  required LocalKey key,
  required Widget child,
}) {
  return CustomTransitionPage<void>(
    key: key,
    child: child,
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(opacity: animation, child: child);
    },
  );
}

/// Listenable that notifies GoRouter when auth state changes, without
/// recreating the entire router instance.
///
/// TD-84: `Ref.listen` (as opposed to `WidgetRef.listenManual`) ties the
/// listener lifetime to the owning provider. When `routerProvider` is
/// invalidated, Riverpod tears the listener down automatically — there is
/// no separate `ProviderSubscription` to track. We still override
/// `dispose()` so future maintainers know the listener cleanup is
/// delegated to Riverpod, not handled in this class.
class _AuthNotifierListenable extends ChangeNotifier {
  _AuthNotifierListenable(Ref ref) {
    ref.listen(authProvider, (prev, next) => notifyListeners());
  }
}

/// Redirect logic for auth state.
String? _authRedirect(Ref ref, GoRouterState state) {
  final isLoggedIn = ref.read(authProvider).isLoggedIn;
  final isSplash = state.matchedLocation == _routeSplash;
  final isAuthRoute =
      state.matchedLocation == _routeLogin ||
      state.matchedLocation == '/register' ||
      state.matchedLocation == '/forgot-password' ||
      state.matchedLocation == '/reset-password';
  final isOnboarding = state.matchedLocation == '/onboarding';
  final isJoinRoute =
      state.matchedLocation.startsWith('/join') ||
      state.matchedLocation.startsWith('/invite') ||
      state.matchedLocation.startsWith('/u/');

  if (isSplash) return null;

  // Already logged in AND onboarding was previously completed — skip back to home.
  // New accounts have onboardingCompleted=false so they are allowed through.
  final onboardingCompleted = ref.read(authProvider).onboardingCompleted;
  if (isLoggedIn && isOnboarding && onboardingCompleted) return _routeHome;

  if (!isLoggedIn && !isAuthRoute && !isOnboarding && !isJoinRoute) {
    final intended = state.matchedLocation;
    if (intended != _routeHome && intended != _routeLogin) {
      ref.read(_pendingDeepLinkProvider.notifier).set(state.uri.toString());
    }
    return _routeLogin;
  }
  if (isLoggedIn && isAuthRoute) {
    final deepLink = ref.read(_pendingDeepLinkProvider.notifier).takeAndClear();
    if (deepLink != null) {
      return deepLink;
    }
    return _routeHome;
  }
  return null;
}

Widget _buildProfilePage(String userId) {
  return Scaffold(
    appBar: AppBar(title: const Text('Profile')),
    body: UserProfileScreen(userId: userId),
  );
}

/// Profile-related routes plus username invite deep links.
///
/// `/profile/:userId` is the canonical route. Earlier builds shipped a handful
/// of alternative paths (`/u-id/:userId`, `/user/:userId`, `/echo-user/:userId`)
/// that pointed at the same screen — links generated by those builds may still
/// be in the wild (e.g. copy-pasted into chats), so we keep them working as
/// pure redirects to the canonical path. `/u/:username` is intentionally NOT
/// redirected: it resolves an invite username to a profile via a network
/// lookup and renders a different screen.
List<GoRoute> _profileRoutes() {
  String? profileRedirect(BuildContext ctx, GoRouterState state) {
    final id = state.pathParameters['userId'];
    return (id != null && id.isNotEmpty) ? '/profile/$id' : null;
  }

  return [
    GoRoute(
      path: '/profile/:userId',
      pageBuilder: (context, state) => _fadePage(
        key: state.pageKey,
        child: _buildProfilePage(state.pathParameters['userId']!),
      ),
    ),
    GoRoute(path: '/u-id/:userId', redirect: profileRedirect),
    GoRoute(
      path: '/u/:username',
      pageBuilder: (context, state) => _fadePage(
        key: state.pageKey,
        child: UsernameInviteScreen(
          username: state.pathParameters['username']!,
        ),
      ),
    ),
    GoRoute(path: '/user/:userId', redirect: profileRedirect),
    GoRoute(
      path: '/profile',
      redirect: (context, state) {
        final qp = state.uri.queryParameters;
        final userId = qp['userId'] ?? qp['uid'] ?? qp['id'] ?? '';
        if (userId.isEmpty) return _routeHome;
        return '/profile/$userId';
      },
    ),
    GoRoute(path: '/echo-user/:userId', redirect: profileRedirect),
  ];
}

final routerProvider = Provider<GoRouter>((ref) {
  final refreshListenable = _AuthNotifierListenable(ref);

  return GoRouter(
    initialLocation: _routeSplash,
    refreshListenable: refreshListenable,
    redirect: (context, state) => _authRedirect(ref, state),
    routes: [
      GoRoute(
        path: _routeSplash,
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const SplashScreen()),
      ),
      GoRoute(
        path: _routeLogin,
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const LoginScreen()),
      ),
      GoRoute(
        path: '/register',
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const RegisterScreen()),
      ),
      GoRoute(
        path: '/forgot-password',
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const ForgotPasswordScreen()),
      ),
      GoRoute(
        path: '/reset-password',
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const ResetPasswordScreen()),
      ),
      GoRoute(
        path: '/onboarding',
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const OnboardingWizard()),
      ),
      GoRoute(
        path: _routeHome,
        pageBuilder: (context, state) {
          final conversationId = state.uri.queryParameters['conversation'];
          final messageId = state.uri.queryParameters['messageId'];
          return _fadePage(
            key: state.pageKey,
            child: HomeScreen(
              initialConversationId: conversationId,
              initialMessageId: messageId,
            ),
          );
        },
      ),
      GoRoute(
        path: '/contacts',
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const ContactsScreen()),
      ),
      GoRoute(
        path: '/create-group',
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const CreateGroupScreen()),
      ),
      GoRoute(
        path: '/group-info/:conversationId',
        pageBuilder: (context, state) => _fadePage(
          key: state.pageKey,
          child: GroupInfoScreen(
            conversationId: state.pathParameters['conversationId']!,
          ),
        ),
      ),
      GoRoute(
        path: '/discover-groups',
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const DiscoverGroupsScreen()),
      ),
      GoRoute(
        path: '/settings',
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const SettingsScreen()),
      ),
      GoRoute(
        path: '/saved',
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const SavedMessagesScreen()),
      ),
      // Admin dashboard (issue #682). The server's `AdminUser` extractor
      // already 403s non-admins on the underlying API calls, so even
      // without a route-level gate the screen renders an error for them.
      // Route-level gating on `auth.isAdmin` is deferred — see the PR
      // description; it needs the server's login response to surface the
      // `is_admin` flag, which is out of scope for this client-only slice.
      GoRoute(
        path: '/admin',
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const AdminDashboardScreen()),
      ),
      GoRoute(
        path: '/safety-number/:peerId',
        pageBuilder: (context, state) {
          final peerId = state.pathParameters['peerId']!;
          final qp = state.uri.queryParameters;
          final peerUsername = qp['peerUsername'] ?? peerId;
          final myUsername = qp['myUsername'] ?? '';
          return _fadePage(
            key: state.pageKey,
            child: SafetyNumberScreen(
              peerUserId: peerId,
              peerUsername: peerUsername,
              myUsername: myUsername,
            ),
          );
        },
      ),
      GoRoute(
        path: '/join/:groupId',
        pageBuilder: (context, state) => _fadePage(
          key: state.pageKey,
          child: JoinGroupScreen(groupId: state.pathParameters['groupId']!),
        ),
      ),
      GoRoute(
        path: '/join',
        redirect: (context, state) {
          final qp = state.uri.queryParameters;
          final groupId =
              qp['groupId'] ?? qp['gid'] ?? qp['id'] ?? qp['invite'] ?? '';
          if (groupId.isEmpty) return _routeHome;
          return '/join/$groupId';
        },
      ),
      GoRoute(
        path: '/invite/:groupId',
        pageBuilder: (context, state) => _fadePage(
          key: state.pageKey,
          child: JoinGroupScreen(groupId: state.pathParameters['groupId']!),
        ),
      ),
      GoRoute(
        path: '/invite/t/:token',
        pageBuilder: (context, state) => _fadePage(
          key: state.pageKey,
          child: TokenJoinScreen(token: state.pathParameters['token']!),
        ),
      ),
      ..._profileRoutes(),
      // Debug-only testbed for the centralised context menu. Stripped
      // from release builds so it can't be linked-to by accident.
      if (kDebugMode)
        GoRoute(
          path: '/dev/context-menu',
          pageBuilder: (context, state) =>
              _fadePage(key: state.pageKey, child: const ContextMenuTestbed()),
        ),
    ],
  );
});
