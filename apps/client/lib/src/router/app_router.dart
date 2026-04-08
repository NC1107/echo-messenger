import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../screens/contacts_screen.dart';
import '../screens/create_group_screen.dart';
import '../screens/discover_groups_screen.dart';
import '../screens/group_info_screen.dart';
import '../screens/home_screen.dart';
import '../screens/join_group_screen.dart';
import '../screens/login_screen.dart';
import '../screens/onboarding_wizard.dart';
import '../screens/register_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/splash_screen.dart';
import '../screens/user_profile_screen.dart';

const _routeHome = '/home';
const _routeLogin = '/login';
const _routeSplash = '/splash';

/// Stores a deep link path that was requested before the user was
/// authenticated. After login or splash auto-login, the app navigates
/// here instead of /home.
String? pendingDeepLink;

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
class _AuthNotifierListenable extends ChangeNotifier {
  _AuthNotifierListenable(Ref ref) {
    ref.listen(authProvider, (prev, next) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refreshListenable = _AuthNotifierListenable(ref);

  Widget buildProfilePage(String userId) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: UserProfileScreen(userId: userId),
    );
  }

  return GoRouter(
    initialLocation: _routeSplash,
    refreshListenable: refreshListenable,
    redirect: (context, state) {
      final isLoggedIn = ref.read(authProvider).isLoggedIn;
      final isSplash = state.matchedLocation == _routeSplash;
      final isAuthRoute =
          state.matchedLocation == _routeLogin ||
          state.matchedLocation == '/register';
      final isOnboarding = state.matchedLocation == '/onboarding';

      // Let the splash screen handle its own navigation
      if (isSplash) return null;

      if (!isLoggedIn && !isAuthRoute && !isOnboarding) {
        // Save the intended path so we can navigate there after login
        final intended = state.matchedLocation;
        if (intended != _routeHome && intended != _routeLogin) {
          pendingDeepLink = state.uri.toString();
        }
        return _routeLogin;
      }
      if (isLoggedIn && isAuthRoute) return _routeHome;
      return null;
    },
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
        path: '/onboarding',
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const OnboardingWizard()),
      ),
      GoRoute(
        path: _routeHome,
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const HomeScreen()),
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
        path: '/profile/:userId',
        pageBuilder: (context, state) => _fadePage(
          key: state.pageKey,
          child: buildProfilePage(state.pathParameters['userId']!),
        ),
      ),
      GoRoute(
        path: '/u/:userId',
        pageBuilder: (context, state) => _fadePage(
          key: state.pageKey,
          child: buildProfilePage(state.pathParameters['userId']!),
        ),
      ),
      GoRoute(
        path: '/user/:userId',
        pageBuilder: (context, state) => _fadePage(
          key: state.pageKey,
          child: buildProfilePage(state.pathParameters['userId']!),
        ),
      ),
      GoRoute(
        path: '/profile',
        redirect: (context, state) {
          final qp = state.uri.queryParameters;
          final userId = qp['userId'] ?? qp['uid'] ?? qp['id'] ?? '';
          if (userId.isEmpty) return _routeHome;
          return '/profile/$userId';
        },
      ),
      GoRoute(
        path: '/echo-user/:userId',
        pageBuilder: (context, state) => _fadePage(
          key: state.pageKey,
          child: buildProfilePage(state.pathParameters['userId']!),
        ),
      ),
    ],
  );
});
