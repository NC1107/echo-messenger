import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../screens/chat_screen.dart';
import '../screens/contacts_screen.dart';
import '../screens/conversations_screen.dart';
import '../screens/create_group_screen.dart';
import '../screens/group_info_screen.dart';
import '../screens/login_screen.dart';
import '../screens/register_screen.dart';

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
      if (isLoggedIn && isAuthRoute) return '/conversations';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/conversations',
        builder: (context, state) => const ConversationsScreen(),
      ),
      GoRoute(
        path: '/contacts',
        builder: (context, state) => const ContactsScreen(),
      ),
      GoRoute(
        path: '/create-group',
        builder: (context, state) => const CreateGroupScreen(),
      ),
      GoRoute(
        path: '/chat/:userId',
        builder: (_, state) => ChatScreen(
          userId: state.pathParameters['userId']!,
          username: state.uri.queryParameters['username'] ?? 'Unknown',
          conversationId: state.uri.queryParameters['conversationId'],
          isGroup: false,
        ),
      ),
      GoRoute(
        path: '/chat-group/:conversationId',
        builder: (_, state) => ChatScreen(
          userId: '', // Not used for group chats
          username: state.uri.queryParameters['name'] ?? 'Group',
          conversationId: state.pathParameters['conversationId'],
          isGroup: true,
        ),
      ),
      GoRoute(
        path: '/group-info/:conversationId',
        builder: (_, state) => GroupInfoScreen(
          conversationId: state.pathParameters['conversationId']!,
        ),
      ),
    ],
  );
});
