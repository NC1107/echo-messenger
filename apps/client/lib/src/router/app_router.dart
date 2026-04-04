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
import '../screens/register_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/user_profile_screen.dart';

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

final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authProvider);

  Widget buildProfilePage(String userId) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: UserProfileScreen(userId: userId),
    );
  }

  return GoRouter(
    initialLocation: '/login',
    redirect: (context, state) {
      final isLoggedIn = authState.isLoggedIn;
      final isAuthRoute =
          state.matchedLocation == '/login' ||
          state.matchedLocation == '/register';

      if (!isLoggedIn && !isAuthRoute) return '/login';
      if (isLoggedIn && isAuthRoute) return '/home';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const LoginScreen()),
      ),
      GoRoute(
        path: '/register',
        pageBuilder: (context, state) =>
            _fadePage(key: state.pageKey, child: const RegisterScreen()),
      ),
      GoRoute(
        path: '/home',
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
          if (groupId.isEmpty) return '/home';
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
          if (userId.isEmpty) return '/home';
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
