import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../screens/contacts_screen.dart';
import '../screens/create_group_screen.dart';
import '../screens/discover_groups_screen.dart';
import '../screens/group_info_screen.dart';
import '../screens/home_screen.dart';
import '../screens/login_screen.dart';
import '../screens/register_screen.dart';
import '../screens/settings_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authProvider);

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
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(path: '/home', builder: (context, state) => const HomeScreen()),
      // Keep these as overlay routes that push on top of home
      GoRoute(
        path: '/contacts',
        builder: (context, state) => const ContactsScreen(),
      ),
      GoRoute(
        path: '/create-group',
        builder: (context, state) => const CreateGroupScreen(),
      ),
      GoRoute(
        path: '/group-info/:conversationId',
        builder: (_, state) => GroupInfoScreen(
          conversationId: state.pathParameters['conversationId']!,
        ),
      ),
      GoRoute(
        path: '/discover-groups',
        builder: (context, state) => const DiscoverGroupsScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
  );
});
